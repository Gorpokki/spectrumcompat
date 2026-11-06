#!/usr/bin/env bash
# Boot a headless NeoForge dedicated server with the given mod jar plus Spectrum,
# Vanilla Backport and their required mods. Exits 0 only if the server reaches
# "Done" without crashing or logging a mixin failure.
# Usage: boot-check.sh <mod.jar> <work-dir>
set -euo pipefail

mod_jar=$(realpath "$1")
work=$2
repo=$(cd "$(dirname "$0")/.." && pwd)
neo_version=$(sed -n 's/^neo_version=//p' "$repo/gradle.properties")
timeout_s=${BOOT_TIMEOUT:-600}

mkdir -p "$work/mods"
cd "$work"

fetch() { # sha256 url dest
  curl -sSfL --retry 3 -o "$3" "$2"
  echo "$1  $3" | sha256sum -c -
}

# NeoForge 21.1.226 installer; update the hash when neo_version changes.
fetch 7ad8225fa9959aa155e7ff3d68e126c81d50bdd7d0e224f460cf89af5468bfdb \
  "https://maven.neoforged.net/releases/net/neoforged/neoforge/$neo_version/neoforge-$neo_version-installer.jar" \
  installer.jar

# Pinned Modrinth releases. Spectrum 1.12.5 is the newest release that accepts
# NeoForge 21.1.226 (1.12.6+ need 21.1.249); Revelationary 1.5.1 likewise.
while read -r sha url; do
  fetch "$sha" "$url" "mods/${url##*/}"
done <<'EOF'
bc20f367936c963feca7cc5c2b97d452d3892269b76198932ffb538eb6c10d4f https://cdn.modrinth.com/data/3rc31Hgo/versions/cE3gyVDM/spectrum-1.12.5-1.21.1-neo.jar
6cd105ccdeb08921aae5f328fb610ace8cceef994663bf796cc3dbfa4f385cf9 https://cdn.modrinth.com/data/eXrl5E3G/versions/3XGPyKNr/revelationary-neoforge-1.5.1%2B1.21.1.jar
23f02535d579602d3da3e15397c9edc55b9dcafb6b755c1665f31d70fa6bec1f https://cdn.modrinth.com/data/692GClaE/versions/OKyLanIn/modonomicon-1.21.1-neoforge-1.123.0.jar
a45df2125c26219974aba7507ffc9afe7b83acc941a386af3faacb1cc0056fde https://cdn.modrinth.com/data/vvuO3ImH/versions/yohfFbgD/curios-neoforge-9.5.1%2B1.21.1.jar
af66aa2458f21c691b5c0feb14439e15c72e14051ed592050df1b6bf8bdeb089 https://cdn.modrinth.com/data/6xwxDTgf/versions/mGS7BxD4/VanillaBackport-neoforge-1.21.1-1.2.2.jar
56f63d73614e35841f6f8ac79d2eb2f7d8b9ff6414272eecac19274644c849ac https://cdn.modrinth.com/data/i6fiqm5y/versions/rh4p4ixM/Platform-neoforge-1.21.1-1.4.2.jar
EOF
cp "$mod_jar" mods/

java -jar installer.jar --installServer . > install.log 2>&1 || { tail -50 install.log; exit 1; }
echo "eula=true" > eula.txt
echo "-Xmx2G" > user_jvm_args.txt

mkfifo console
sleep infinity > console &
holder=$!
./run.sh nogui < console > server.log 2>&1 &
server=$!
trap 'set +e; { kill $holder; pkill -P $server; kill $server; wait $server; } 2>/dev/null' EXIT
trap 'exit 1' INT TERM

result=timeout
for _ in $(seq "$timeout_s"); do
  if grep -q 'Done ([0-9.]*s)!' server.log; then result=ready; break; fi
  if ! kill -0 "$server" 2>/dev/null; then result=exited; break; fi
  sleep 1
done
[ "$result" = ready ] && { echo stop > console; wait "$server" || true; }

echo "boot result: $result"
if [ "$result" != ready ] || grep -qiE 'Mixin apply.*failed|MixinApplyError|InvalidInjectionException|InvalidMixinException|Mixin transformation of .* failed|---- Minecraft Crash Report ----' server.log logs/latest.log 2>/dev/null; then
  grep -iE -m 40 'mixin|crash|exception|error' server.log || tail -80 server.log
  exit 1
fi
echo "server booted cleanly"
