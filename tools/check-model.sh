#!/usr/bin/env bash
set -euo pipefail
: "${TLA_JAR:?Set TLA_JAR to a local tla2tools.jar path}"
cd "$(dirname "$0")/../spec"
java -XX:+UseParallelGC -cp "$TLA_JAR" tlc2.TLC -workers 1 -config Capture.cfg Capture.tla
java -XX:+UseParallelGC -cp "$TLA_JAR" tlc2.TLC -workers 1 -config Progress.cfg Capture.tla
java -XX:+UseParallelGC -cp "$TLA_JAR" tlc2.TLC -workers 1 -config Recovery.cfg Capture.tla
java -XX:+UseParallelGC -cp "$TLA_JAR" tlc2.TLC -workers 1 -config AppRecovery.cfg AppRecovery.tla
java -XX:+UseParallelGC -cp "$TLA_JAR" tlc2.TLC -workers 1 -config Rolodex.cfg Rolodex.tla
