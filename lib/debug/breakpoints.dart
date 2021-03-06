library atom.breakpoints;

import 'dart:async';

import 'package:logging/logging.dart';

import '../atom.dart';
import '../projects.dart';
import '../state.dart';
import '../utils.dart';
import 'utils.dart';

final Logger _logger = new Logger('atom.breakpoints');

// TODO: Allow files outside the workspace?

// TODO: Error message when they explicitly set a breakpoint, but not if an
// existing one fails to apply.

// TODO: When setting breakpoints, adjust to where the VM actually set the
// breakpoint.

// TODO: No breakpoints on ws or comment lines.

// TODO: listen to clicks / double clicks on the line number getter.

class BreakpointManager implements Disposable, StateStorable {
  Disposables disposables = new Disposables();

  List<AtomBreakpoint> _breakpoints = [];
  List<_EditorBreakpoint> _editorBreakpoints = [];

  StreamController<AtomBreakpoint> _addController = new StreamController.broadcast();
  StreamController<AtomBreakpoint> _changeController = new StreamController.broadcast();
  StreamController<AtomBreakpoint> _removeController = new StreamController.broadcast();

  BreakpointManager() {
    disposables.add(atom.commands.add('atom-workspace', 'dartlang:debug-toggle-breakpoint', (_) {
      _toggleBreakpoint();
    }));

    editorManager.dartEditors.openEditors.forEach(_processEditor);
    editorManager.dartEditors.onEditorOpened.listen(_processEditor);

    state.registerStorable('breakpoints', this);
  }

  void addBreakpoint(AtomBreakpoint breakpoint) {
    _breakpoints.add(breakpoint);
    _addController.add(breakpoint);

    for (TextEditor editor in editorManager.dartEditors.openEditors) {
      if (editor.getPath() == breakpoint.path) {
        _createEditorBreakpoint(editor, breakpoint);
      }
    }
  }

  List<AtomBreakpoint> get breakpoints => new List.from(_breakpoints);

  Iterable<AtomBreakpoint> getBreakpontsFor(String path) {
    return _breakpoints.where((bp) => bp.path == path);
  }

  void removeBreakpoint(AtomBreakpoint breakpoint) {
    _breakpoints.remove(breakpoint);
    _removeController.add(breakpoint);

    for (_EditorBreakpoint editorBreakpoint in _editorBreakpoints.toList()) {
      if (editorBreakpoint.bp == breakpoint) {
        _removeEditorBreakpoint(editorBreakpoint);
        editorBreakpoint.dispose();
      }
    }
  }

  Stream<AtomBreakpoint> get onAdd => _addController.stream;

  /// Fired when a breakpoint changes position (line or column).
  Stream<AtomBreakpoint> get onChange => _changeController.stream;

  Stream<AtomBreakpoint> get onRemove => _removeController.stream;

  void _processEditor(TextEditor editor) {
    // Install any applicable breakpoints.
    getBreakpontsFor(editor.getPath()).forEach((AtomBreakpoint bp) {
      _createEditorBreakpoint(editor, bp);
    });
  }

  void _createEditorBreakpoint(TextEditor editor, AtomBreakpoint bp) {
    _logger.finer('creating editor breakpoint: ${bp}');
    Marker marker = editor.markBufferRange(
        debuggerCoordsToEditorRange(bp.line, bp.column),
        persistent: false);
    _editorBreakpoints.add(new _EditorBreakpoint(this, editor, bp, marker));
  }

  void _toggleBreakpoint() {
    TextEditor editor = atom.workspace.getActiveTextEditor();

    if (editor == null) {
      atom.beep();
      return;
    }

    String path = editor.getPath();
    if (!isDartFile(path)) {
      atom.notifications.addWarning('Breakpoints only supported for Dart files.');
      return;
    }

    // For now, we just create line breakpoints; use the column (`p.column`)
    // when we have a context menu item.
    Point p = editor.getCursorBufferPosition();
    AtomBreakpoint bp = new AtomBreakpoint(path, p.row + 1);
    AtomBreakpoint other = _findSimilar(bp);

    // Check to see if we need to toggle it.
    if (other != null) {
      atom.notifications.addInfo('Removed ${other.display}');
      removeBreakpoint(other);
    } else {
      atom.notifications.addSuccess('Added ${bp.display}');
      addBreakpoint(bp);
    }
  }

  /// Find a breakpoint on the same file and line.
  AtomBreakpoint _findSimilar(AtomBreakpoint other) {
    return _breakpoints.firstWhere((AtomBreakpoint bp) {
      return other.path == bp.path && other.line == bp.line;
    }, orElse: () => null);
  }

  void _removeEditorBreakpoint(_EditorBreakpoint bp) {
    _logger.fine('removing editor breakpoint: ${bp.bp}');
    _editorBreakpoints.remove(bp);
  }

  void _updateBreakpointLocation(AtomBreakpoint bp, Range range) {
    LineColumn lineCol = editorRangeToDebuggerCoords(range);
    bp.updateLocation(lineCol);
    _changeController.add(bp);
  }

  void initFromStored(dynamic storedData) {
    if (storedData is List) {
      for (var json in storedData) {
        AtomBreakpoint bp = new AtomBreakpoint.fromJson(json);
        if (bp.fileExists()) addBreakpoint(bp);
      }

      _logger.fine('restored ${_breakpoints.length} breakpoints');
    }
  }

  dynamic toStorable() {
    return _breakpoints.map((AtomBreakpoint bp) => bp.toJsonable()).toList();
  }

  void dispose() => disposables.dispose();
}

class AtomBreakpoint implements Comparable {
  final String path;
  int _line;
  int _column;

  AtomBreakpoint(this.path, int line, {int column}) {
    _line = line;
    _column = column;
  }

  AtomBreakpoint.fromJson(json) :
      path = json['path'], _line = json['line'], _column = json['column'];

  int get line => _line;
  int get column => _column;

  String get asUrl => 'file://${path}';

  String get id => column == null ? '[${path}:${line}]' : '[${path}:${line}:${column}]';

  String get display {
    if (column == null) {
      return '${getWorkspaceRelativeDescription(path)}, ${line}';
    } else {
      return '${getWorkspaceRelativeDescription(path)}, ${line}:${column}';
    }
  }

  /// Return whether the file associated with this breakpoint exists.
  bool fileExists() => existsSync(path);

  void updateLocation(LineColumn lineCol) {
    _line = lineCol.line;
    _column = lineCol.column;
  }

  int get hashCode => id.hashCode;
  bool operator==(other) => other is AtomBreakpoint && id == other.id;

  Map toJsonable() {
    if (column == null) {
      return {'path': path, 'line': line};
    } else {
      return {'path': path, 'line': line, 'column': column};
    }
  }

  String toString() => id;

  int compareTo(other) {
    if (other is! AtomBreakpoint) return -1;

    int val = path.compareTo(other.path);
    if (val != 0) return val;

    val = line - other.line;
    if (val != 0) return val;

    int col_a = column == null ? -1 : column;
    int col_b = other.column == null ? -1 : other.column;
    return col_a - col_b;
  }
}

class _EditorBreakpoint implements Disposable {
  final BreakpointManager manager;
  final TextEditor editor;
  final AtomBreakpoint bp;
  final Marker marker;

  Range _range;

  StreamSubscriptions subs = new StreamSubscriptions();

  _EditorBreakpoint(this.manager, this.editor, this.bp, this.marker) {
    _range = marker.getBufferRange();

    editor.decorateMarker(marker, {
      'type': 'line-number',
      'class': 'debugger-breakpoint'
    });

    subs.add(marker.onDidChange.listen((e) {
      if (!marker.isValid()) {
        manager.removeBreakpoint(bp);
      } else {
        _checkForLocationChange();
      }
    }));
  }

  void _checkForLocationChange() {
    Range newRange = marker.getBufferRange();
    if (_range != newRange) {

      _range = newRange;
      manager._updateBreakpointLocation(bp, newRange);
    }
  }

  void dispose() {
    subs.cancel();
    marker.destroy();
  }
}
