/*
 * Copyright 2023 The TensorFlow Authors. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *             http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:quiver/check.dart';
import 'package:tflite_flutter/src/bindings/bindings.dart';
import 'package:tflite_flutter/src/bindings/tensorflow_lite_bindings_generated.dart';

import 'ffi/helper.dart';
import 'interpreter_options.dart';
import 'model.dart';
import 'tensor.dart';

/// TensorFlowLite interpreter for running inference on a model.
class Interpreter {
  final Pointer<TfLiteInterpreter> _interpreter;
  final Map<String, Pointer<TfLiteSignatureRunner>> _signatureRunners = {};
  bool _deleted = false;
  bool _allocated = false;
  int _lastNativeInferenceDurationMicroSeconds = 0;

  List<Tensor>? _inputTensors;
  List<Tensor>? _outputTensors;

  int? _inputTensorsCount;
  int? _outputTensorsCount;

  int get lastNativeInferenceDurationMicroSeconds =>
      _lastNativeInferenceDurationMicroSeconds;

  Interpreter._(this._interpreter) {
    // Allocate tensors when interpreter is created
    allocateTensors();
  }

  /// Creates interpreter from model
  ///
  /// Throws [ArgumentError] is unsuccessful.
  factory Interpreter._create(Model model, {InterpreterOptions? options}) {
    final interpreter = tfliteBinding.TfLiteInterpreterCreate(
        model.base, options?.base ?? cast<TfLiteInterpreterOptions>(nullptr));
    checkArgument(isNotNull(interpreter),
        message: 'Unable to create interpreter.');
    return Interpreter._(interpreter);
  }

  /// Creates [Interpreter] from a model file
  ///
  /// Throws [ArgumentError] if unsuccessful.
  ///
  /// Example:
  ///
  /// ```dart
  /// final dataFile = await getFile('assets/your_model.tflite');
  /// final interpreter = Interpreter.fromFile(dataFile);
  ///
  /// Future<File> getFile(String fileName) async {
  ///   final appDir = await getTemporaryDirectory();
  ///   final appPath = appDir.path;
  ///   final fileOnDevice = File('$appPath/$fileName');
  ///   final rawAssetFile = await rootBundle.load(fileName);
  ///   final rawBytes = rawAssetFile.buffer.asUint8List();
  ///   await fileOnDevice.writeAsBytes(rawBytes, flush: true);
  ///   return fileOnDevice;
  /// }
  /// ```
  factory Interpreter.fromFile(File modelFile, {InterpreterOptions? options}) {
    final model = Model.fromFile(modelFile.path);
    final interpreter = Interpreter._create(model, options: options);
    model.delete();
    return interpreter;
  }

  /// Creates interpreter from a [buffer]
  ///
  /// Throws [ArgumentError] if unsuccessful.
  ///
  /// Example:
  ///
  /// ```dart
  ///   final buffer = await getBuffer('assets/your_model.tflite');
  ///   final interpreter = Interpreter.fromBuffer(buffer);
  ///
  ///   Future<Uint8List> getBuffer(String filePath) async {
  ///       final rawAssetFile = await rootBundle.load(filePath);
  ///       final rawBytes = rawAssetFile.buffer.asUint8List();
  ///       return rawBytes;
  ///   }
  /// ```
  factory Interpreter.fromBuffer(Uint8List buffer,
      {InterpreterOptions? options}) {
    final model = Model.fromBuffer(buffer);
    final interpreter = Interpreter._create(model, options: options);
    model.delete();
    return interpreter;
  }

  /// Creates interpreter from a [assetName]
  ///
  /// Place your `.tflite` file in your assets folder.
  ///
  /// Example:
  ///
  /// ```dart
  /// final interpreter = await tfl.Interpreter.fromAsset('assets/your_model.tflite');
  /// ```
  static Future<Interpreter> fromAsset(String assetName,
      {InterpreterOptions? options}) async {
    Uint8List buffer = await _getBuffer(assetName);
    return Interpreter.fromBuffer(buffer, options: options);
  }

  /// Get byte buffer
  static Future<Uint8List> _getBuffer(String assetFileName) async {
    ByteData rawAssetFile = await rootBundle.load(assetFileName);
    final rawBytes = rawAssetFile.buffer.asUint8List();
    return rawBytes;
  }

  /// Creates interpreter from an address.
  ///
  /// Typically used for passing interpreter between isolates.
  factory Interpreter.fromAddress(int address,
      {bool allocated = false, bool deleted = false}) {
    final interpreter = Pointer<TfLiteInterpreter>.fromAddress(address);
    return Interpreter._(interpreter)
      .._deleted = deleted
      .._allocated = allocated;
  }

  /// Destroys the interpreter instance.
  void close() {
    checkState(!_deleted, message: 'Interpreter already deleted.');
    tfliteBinding.TfLiteInterpreterDelete(_interpreter);
    _deleted = true;
  }

  /// Updates allocations for all tensors.
  void allocateTensors() {
    checkState(tfliteBinding.TfLiteInterpreterAllocateTensors(_interpreter) ==
        TfLiteStatus.kTfLiteOk);
    _allocated = true;
  }

  /// Runs inference for the loaded graph.
  void invoke() {
    checkState(_allocated, message: 'Interpreter not allocated.');
    checkState(tfliteBinding.TfLiteInterpreterInvoke(_interpreter) ==
        TfLiteStatus.kTfLiteOk);
  }

  /// Run for single input and output
  void run(Object input, Object output) {
    var map = <int, Object>{};
    map[0] = output;
    runForMultipleInputs([input], map);
  }

  /// Run for multiple inputs and outputs
  void runForMultipleInputs(List<Object> inputs, Map<int, Object> outputs) {
    if (outputs.isEmpty) {
      throw ArgumentError('Input error: Outputs should not be null or empty.');
    }
    runInference(inputs);
    var outputTensors = getOutputTensors();
    for (var i = 0; i < outputTensors.length; i++) {
      outputTensors[i].copyTo(outputs[i]!);
    }
  }

  /// Just run inference
  void runInference(List<Object> inputs) {
    if (inputs.isEmpty) {
      throw ArgumentError('Input error: Inputs should not be null or empty.');
    }

    var inputTensors = getInputTensors();

    for (int i = 0; i < inputs.length; i++) {
      var tensor = inputTensors.elementAt(i);
      final newShape = tensor.getInputShapeIfDifferent(inputs[i]);
      if (newShape != null) {
        resizeInputTensor(i, newShape);
      }
    }

    if (!_allocated) {
      allocateTensors();
      _allocated = true;
    }

    inputTensors = getInputTensors();
    for (int i = 0; i < inputs.length; i++) {
      inputTensors.elementAt(i).setTo(inputs[i]);
    }

    var inferenceStartNanos = DateTime.now().microsecondsSinceEpoch;
    invoke();
    _lastNativeInferenceDurationMicroSeconds =
        DateTime.now().microsecondsSinceEpoch - inferenceStartNanos;
  }

  /// Gets all input tensors associated with the model.
  List<Tensor> getInputTensors() {
    if (_inputTensors != null) {
      return _inputTensors!;
    }

    var tensors = List.generate(
        tfliteBinding.TfLiteInterpreterGetInputTensorCount(_interpreter),
        (i) => Tensor(
            tfliteBinding.TfLiteInterpreterGetInputTensor(_interpreter, i)),
        growable: false);

    return tensors;
  }

  /// Gets all output tensors associated with the model.
  List<Tensor> getOutputTensors() {
    if (_outputTensors != null) {
      return _outputTensors!;
    }

    var tensors = List.generate(
        tfliteBinding.TfLiteInterpreterGetOutputTensorCount(_interpreter),
        (i) => Tensor(
            tfliteBinding.TfLiteInterpreterGetOutputTensor(_interpreter, i)),
        growable: false);

    return tensors;
  }

  /// Resize input tensor for the given tensor index. `allocateTensors` must be called again afterward.
  void resizeInputTensor(int tensorIndex, List<int> shape) {
    final dimensionSize = shape.length;
    final dimensions = calloc<Int>(dimensionSize);
    final externalTypedData =
        dimensions.cast<Int32>().asTypedList(dimensionSize);
    externalTypedData.setRange(0, dimensionSize, shape);
    final status = tfliteBinding.TfLiteInterpreterResizeInputTensor(
        _interpreter, tensorIndex, dimensions, dimensionSize);
    calloc.free(dimensions);
    checkState(status == TfLiteStatus.kTfLiteOk);
    _inputTensors = null;
    _outputTensors = null;
    _allocated = false;
  }

  /// Gets the input Tensor for the provided input index.
  Tensor getInputTensor(int index) {
    _inputTensorsCount ??=
        tfliteBinding.TfLiteInterpreterGetInputTensorCount(_interpreter);
    if (index < 0 || index >= _inputTensorsCount!) {
      throw ArgumentError('Invalid input Tensor index: $index');
    }
    if (_inputTensors != null) {
      return _inputTensors![index];
    }

    final inputTensor = Tensor(
        tfliteBinding.TfLiteInterpreterGetInputTensor(_interpreter, index));
    return inputTensor;
  }

  /// Gets the output Tensor for the provided output index.
  Tensor getOutputTensor(int index) {
    _outputTensorsCount ??=
        tfliteBinding.TfLiteInterpreterGetOutputTensorCount(_interpreter);
    if (index < 0 || index >= _outputTensorsCount!) {
      throw ArgumentError('Invalid output Tensor index: $index');
    }
    if (_outputTensors != null) {
      return _outputTensors![index];
    }
    final outputTensor = Tensor(
        tfliteBinding.TfLiteInterpreterGetOutputTensor(_interpreter, index));
    return outputTensor;
  }

  /// Gets index of an input given the op name of the input.
  int getInputIndex(String opName) {
    final inputTensors = getInputTensors();
    var inputTensorsIndex = <String, int>{};
    for (var i = 0; i < inputTensors.length; i++) {
      inputTensorsIndex[inputTensors[i].name] = i;
    }
    if (inputTensorsIndex.containsKey(opName)) {
      return inputTensorsIndex[opName]!;
    } else {
      throw ArgumentError(
          "Input error: $opName' is not a valid name for any input. Names of inputs and their indexes are $inputTensorsIndex");
    }
  }

  /// Gets index of an output given the op name of the output.
  int getOutputIndex(String opName) {
    final outputTensors = getOutputTensors();
    var outputTensorsIndex = <String, int>{};
    for (var i = 0; i < outputTensors.length; i++) {
      outputTensorsIndex[outputTensors[i].name] = i;
    }
    if (outputTensorsIndex.containsKey(opName)) {
      return outputTensorsIndex[opName]!;
    } else {
      throw ArgumentError(
          "Output error: $opName' is not a valid name for any output. Names of outputs and their indexes are $outputTensorsIndex");
    }
  }

  // Resets all variable tensors to the default value
  void resetVariableTensors() {
    checkState(_deleted,
        message: 'Should not access delegate after it has been closed.');
    // loop through signatureRunners and delete them
    _signatureRunners.forEach((key, value) {
      _deleteSignatureRunner(value);
    });
    tfliteBinding.TfLiteInterpreterResetVariableTensors(_interpreter);
  }

  /// Get signature runner by signature key.
  Pointer<TfLiteSignatureRunner> _getSignatureRunner(String signatureKey) {
    // check if signature key exists
    if (!_signatureRunners.containsKey(signatureKey)) {
      Pointer<Char> signatureKeyPointer =
      signatureKey.toNativeUtf8() as Pointer<Char>;
      final signatureRunner = tfliteBinding.TfLiteInterpreterGetSignatureRunner(
          _interpreter, signatureKeyPointer);
      _signatureRunners[signatureKey] = signatureRunner;
      return signatureRunner;
    } else {
      return _signatureRunners[signatureKey]!;
    }
  }

  /// Gets the number of inputs associated with a signature
  int getSignatureInputCount(String signatureKey) {
    final signatureRunner = _getSignatureRunner(signatureKey);
    final subGraphIndex =
    tfliteBinding.TfLiteSignatureRunnerGetInputCount(signatureRunner);
    return subGraphIndex;
  }

  /// Get the number of outputs associated with a signature
  int getSignatureOutputCount(String signatureKey) {
    final signatureRunner = _getSignatureRunner(signatureKey);
    final subGraphIndex =
    tfliteBinding.TfLiteSignatureRunnerGetOutputCount(signatureRunner);
    return subGraphIndex;
  }

  /// Get input name by index and signature key.
  String getSignatureInputName(String signatureKey, int index) {
    final signatureRunner = _getSignatureRunner(signatureKey);
    final inputName =
    tfliteBinding.TfLiteSignatureRunnerGetInputName(signatureRunner, index);
    return inputName.cast<Utf8>().toDartString();
  }

  /// Get output name by index and signature key.
  String getSignatureOutputName(String signatureKey, int index) {
    final signatureRunner = _getSignatureRunner(signatureKey);
    final outputName = tfliteBinding.TfLiteSignatureRunnerGetOutputName(
        signatureRunner, index);
    return outputName.cast<Utf8>().toDartString();
  }

  List<int> getSignatureInputTensorShape(String signatureKey,
      String inputName) {
    final signatureRunner = _getSignatureRunner(signatureKey);
    final inputTensor = Tensor(
        tfliteBinding.TfLiteSignatureRunnerGetInputTensor(
            signatureRunner, inputName.toNativeUtf8().cast<Char>()));
    final shape = inputTensor.shape;
    return shape;
  }

  List<int> getSignatureOutputTensorShape(String signatureKey,
      String outputName) {
    final signatureRunner = _getSignatureRunner(signatureKey);
    final outputTensor = Tensor(
        tfliteBinding.TfLiteSignatureRunnerGetOutputTensor(
            signatureRunner, outputName.toNativeUtf8().cast<Char>()));
    final shape = outputTensor.shape;
    return shape;
  }

  /// Resize input tensor for the given tensor index. `allocateTensors` must be called again afterward.
  void resizeSignatureInputTensor(
      Pointer<TfLiteSignatureRunner> signatureRunner,
      String inputName,
      List<int> shape) {
    final dimensionSize = shape.length;
    final dimensions = calloc<Int>(dimensionSize);
    final externalTypedData =
    dimensions.cast<Int32>().asTypedList(dimensionSize);
    externalTypedData.setRange(0, dimensionSize, shape);
    final inputNamePointer = inputName.toNativeUtf8().cast<Char>();
    final status = tfliteBinding.TfLiteSignatureRunnerResizeInputTensor(
        signatureRunner, inputNamePointer, dimensions, dimensionSize);
    calloc.free(dimensions);
    checkState(status == TfLiteStatus.kTfLiteOk);
    _isSignatureAllocate = true;
  }

  bool _isSignatureAllocate = false;

  /// Run for single input and output
  void runSignature(Map<String, Object> inputs, Map<String, Object> outputs,
      String signatureKey) {
    if (inputs.isEmpty) {
      throw ArgumentError('Input error: Inputs should not be null or empty.');
    }
    if (outputs.isEmpty) {
      throw ArgumentError('Input error: Outputs should not be null or empty.');
    }

    final Pointer<TfLiteSignatureRunner> signatureRunner = _getSignatureRunner(
        signatureKey);

    inputs.forEach((key, value) {
      final inputTensor = Tensor(
          tfliteBinding.TfLiteSignatureRunnerGetInputTensor(
              signatureRunner, key.toNativeUtf8().cast<Char>()));
      final newShape = inputTensor.getInputShapeIfDifferent(value);
      if (newShape != null) {
        resizeSignatureInputTensor(signatureRunner, key, newShape);
      }
    });

    if(_isSignatureAllocate){
      allocateTensors();
      _isSignatureAllocate = false;
    }

    inputs.forEach((key, value) {
      final inputTensor = Tensor(
          tfliteBinding.TfLiteSignatureRunnerGetInputTensor(
              signatureRunner, key.toNativeUtf8().cast<Char>()));
      inputTensor.setTo(value);
    });

    tfliteBinding.TfLiteSignatureRunnerInvoke(signatureRunner);

    outputs.forEach((key, value) {
      final outputTensor = Tensor(
          tfliteBinding.TfLiteSignatureRunnerGetOutputTensor(
              signatureRunner, key.toNativeUtf8().cast<Char>()));
      outputTensor.copyTo(value);
    });
  }

  /// Delete signature runner. Should be called before interpreter is deleted.
  void _deleteSignatureRunner(Pointer<TfLiteSignatureRunner> signatureRunner) {
    tfliteBinding.TfLiteSignatureRunnerDelete(signatureRunner);
  }

  void deleteSignatureRunner(String signatureKey) {
    if (_signatureRunners.containsKey(signatureKey)) {
      _deleteSignatureRunner(_signatureRunners[signatureKey]!);
      _signatureRunners.remove(signatureKey);
    }
  }

  /// Returns the address to the interpreter
  int get address => _interpreter.address;

  bool get isAllocated => _allocated;

  bool get isDeleted => _deleted;

  //TODO: (JAVA) void modifyGraphWithDelegate(Delegate delegate)
}
