@JS()
library wasm_pack_module;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../js_utils/wasm_interop.dart' as interop;
import '../../js_utils/wasm_interop.dart';
import '../annotations.dart';
import '../memory.dart';
import '../type_utils.dart';
import '../types.dart';
import 'module.dart';

@JS()
@anonymous
extension type _WasmPackInitOutput._(JSObject _) implements JSObject {
  external interop.WasmMemory get memory;
  external JSFunction? get malloc;
  external JSFunction? get free;
}

@extra
class WasmPackModule extends Module {
  final _WasmPackInitOutput _initOutput;
  final List<WasmSymbol> _exports = [];
  final Map<String, FunctionDescription> _functionExports = {};
  final JSFunction? _mallocFn;
  final JSFunction? _freeFn;

  @override
  List<WasmSymbol> get exports => _exports;

  WasmPackModule._(this._initOutput)
      : _mallocFn = _initOutput.malloc,
        _freeFn = _initOutput.free {
    _extractExports();
  }

  static Future<WasmPackModule> compile(JSObject jsModule) async {
    JSFunction? initFn;
    final String initFunctionName = 'default';

    if (jsModule.hasProperty(initFunctionName.toJS).toDart) {
      initFn = jsModule.getProperty(initFunctionName.toJS) as JSFunction?;
    }

    if (initFn == null || !(initFn.typeofEquals('function'))) {
      throw StateError(
          'Could not find the wasm-pack init function: $initFunctionName');
    }

    final JSPromise<JSObject> initPromise =
        initFn.callAsFunction()! as JSPromise<JSObject>;
    final JSObject initResult = await initPromise.toDart;

    final _WasmPackInitOutput initOutput = initResult as _WasmPackInitOutput;

    if (!initOutput.hasProperty('memory'.toJS).toDart) {
      throw StateError("Wasm-pack module's init output is missing 'memory'.");
    }

    return WasmPackModule._(initOutput);
  }

  void _extractExports() {
    final entries = WrappedJSObject.entries(_initOutput).toDart;
    int functionIndex = 0;

    for (final jsEntry in entries) {
      if (jsEntry == null || jsEntry is! List) {
        throw StateError('Unexpected entry in entries(Module[])!');
      }
      final entry = jsEntry as List;
      final name = entry.first as String;
      final value = entry.last;

      if (name == 'memory' || name == 'default') {
        continue;
      }

      if (value is Function) {
        final JSFunction func = value as JSFunction;
        final funcDesc = func as WrappedJSFunction;
        final desc = FunctionDescription(
          tableIndex: functionIndex++,
          name: name,
          function: func,
          argumentCount: funcDesc.length?.toDartInt ?? 0,
        );
        _exports.add(desc);
        _functionExports[name] = desc;
      }
    }
  }

  @override
  int malloc(int size) {
    if (_mallocFn != null) {
      final result = _mallocFn.callAsFunction(null, size.toJS);
      if (result != null && result.typeofEquals('number')) {
        return (result as JSNumber).toDartInt;
      } else {
        throw StateError(
            'WasmPackModule.malloc returned an unexpected result: $result');
      }
    } else {
      throw StateError('Module does not export a malloc function');
    }
  }

  @override
  void free(int pointer) {
    if (_freeFn != null) {
      _freeFn.callAsFunction(null, pointer.toJS);
    } else {
      throw StateError('Module does not export a free function');
    }
  }

  @override
  @doNotStore
  ByteBuffer get heap {
    return _initOutput.memory.buffer.toDart;
  }

  @override
  interop.WasmTable? get indirectFunctionTable {
    return null;
  }

  @override
  Pointer<T> lookup<T extends NativeType>(String name, Memory memory) {
    final funcDesc = _functionExports[name];
    if (funcDesc != null) {
      if (isNativeFunctionType<T>()) {
        return Pointer<T>.fromAddress(funcDesc.tableIndex, memory);
      } else {
        throw ArgumentError("Function symbol '$name' is not a native type.");
      }
    } else {
      throw ArgumentError(
          "Function symbol '$name' not found in wasm-pack module exports.");
    }
  }

  @override
  bool providesSymbol(String symbolName) {
    return _functionExports.containsKey(symbolName);
  }

  @override
  F lookupFunction<T extends Function, F extends Function>(
      String name, Memory memory) {
    final funcDesc = _functionExports[name];
    if (funcDesc != null) {
      return funcDesc.function as F;
    } else {
      throw ArgumentError(
          "Function symbol '$name' not found in wasm-pack module exports.");
    }
  }
}
