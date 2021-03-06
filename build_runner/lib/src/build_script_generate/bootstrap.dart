// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:build_runner_core/build_runner_core.dart';
import 'package:io/io.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:stack_trace/stack_trace.dart';

import 'package:build_runner/src/build_script_generate/build_script_generate.dart';

final _logger = Logger('Bootstrap');

/// Generates the build script, snapshots it if needed, and runs it.
///
/// Will retry once on [IsolateSpawnException]s to handle SDK updates.
///
/// Returns the exit code from running the build script.
///
/// If an exit code of 75 is returned, this function should be re-ran.
Future<int> generateAndRun(List<String> args, {Logger logger}) async {
  logger ??= _logger;
  ReceivePort exitPort;
  ReceivePort errorPort;
  ReceivePort messagePort;
  StreamSubscription errorListener;
  int scriptExitCode;

  var tryCount = 0;
  var succeeded = false;
  while (tryCount < 2 && !succeeded) {
    tryCount++;
    exitPort?.close();
    errorPort?.close();
    messagePort?.close();
    await errorListener?.cancel();

    try {
      var buildScript = await generateBuildScript();
      File(scriptLocation)
        ..createSync(recursive: true)
        ..writeAsStringSync(buildScript);
    } on CannotBuildException {
      return ExitCode.config.code;
    }

    scriptExitCode = await _createSnapshotIfMissing(logger);
    if (scriptExitCode != 0) return scriptExitCode;

    exitPort = ReceivePort();
    errorPort = ReceivePort();
    messagePort = ReceivePort();
    errorListener = errorPort.listen((e) {
      stderr.writeln('\n\nYou have hit a bug in build_runner');
      stderr.writeln('Please file an issue with reproduction steps at '
          'https://github.com/dart-lang/build/issues\n\n');
      final error = e[0];
      final trace = e[1] as String;
      stderr.writeln(error);
      stderr.writeln(Trace.parse(trace).terse);
      if (scriptExitCode == 0) scriptExitCode = 1;
    });
    try {
      await Isolate.spawnUri(Uri.file(p.absolute(scriptSnapshotLocation)), args,
          messagePort.sendPort,
          onExit: exitPort.sendPort, onError: errorPort.sendPort);
      succeeded = true;
    } on IsolateSpawnException catch (e) {
      if (tryCount > 1) {
        logger.severe(
            'Failed to spawn build script after retry. '
            'This is likely due to a misconfigured builder definition. '
            'See the generated script at $scriptLocation to find errors.',
            e);
        messagePort.sendPort.send(ExitCode.config.code);
        exitPort.sendPort.send(null);
      } else {
        logger.warning(
            'Error spawning build script isolate, this is likely due to a Dart '
            'SDK update. Deleting snapshot and retrying...');
      }
      await File(scriptSnapshotLocation).delete();
    }
  }

  StreamSubscription exitCodeListener;
  exitCodeListener = messagePort.listen((isolateExitCode) {
    if (isolateExitCode is int) {
      scriptExitCode = isolateExitCode;
    } else {
      throw StateError(
          'Bad response from isolate, expected an exit code but got '
          '$isolateExitCode');
    }
    exitCodeListener.cancel();
    exitCodeListener = null;
  });
  await exitPort.first;
  await errorListener.cancel();
  await exitCodeListener?.cancel();

  return scriptExitCode;
}

/// Creates a script snapshot for the build script.
///
/// Returns zero for success or a number for failure which should be set to the
/// exit code.
Future<int> _createSnapshotIfMissing(Logger logger) async {
  var snapshotFile = File(scriptSnapshotLocation);
  String stderr;
  if (!await snapshotFile.exists()) {
    await logTimedAsync(logger, 'Creating build script snapshot...', () async {
      var snapshot = await Process.run(Platform.executable,
          ['--snapshot=$scriptSnapshotLocation', scriptLocation]);
      stderr = snapshot.stderr as String;
    });
    if (!await snapshotFile.exists()) {
      logger.severe('Failed to snapshot build script $scriptLocation.\n'
          'This is likely caused by a misconfigured builder definition.');
      if (stderr.isNotEmpty) {
        logger.severe(stderr);
      }
      return ExitCode.config.code;
    }
  }
  return 0;
}
