#!/bin/bash
# install_tkm_aar.sh <libwebrtc.aar> <version> [repo-dir]
# C182: puts a locally built webrtc-sdk fork AAR into a file Maven repository that android/build.gradle reads
# (default android/local-maven, git-ignored; override with -PtkmWebrtcMavenRepo=<dir>).
set -euo pipefail
AAR=$1; VER=$2
REPO=${3:-$(cd "$(dirname "$0")/.." && pwd)/android/local-maven}
D=$REPO/io/github/webrtc-sdk/android/$VER
mkdir -p "$D"
cp "$AAR" "$D/android-$VER.aar"
cat > "$D/android-$VER.pom" <<POM
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>io.github.webrtc-sdk</groupId>
  <artifactId>android</artifactId>
  <version>$VER</version>
  <packaging>aar</packaging>
</project>
POM
sha256sum "$D/android-$VER.aar"
