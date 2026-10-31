#!/bin/bash
# Self-test: scaffold a throwaway project, build and sign it, then delete it.
# On failure the project is kept in ~/.buildtools/selftest and the full Maven
# output is saved to bt-verify-mvn.log next to this file.
cd "$(dirname "$0")" || exit 1
HERE="$PWD"
{
  echo "START $(date)"
  BT_SKIP_PROFILE=1 BT_GEN_KEYPASS=1 bash ./bt-setup.sh install > /dev/null 2>&1 < /dev/null
  source "$HOME/.zprofile"
  echo "npm cache: ${npm_config_cache:-default ~/.npm}"
  echo "java: $(java -version 2>&1 | head -1) | $(mvn -v | head -1) | node $(node -v) npm $(npm -v)"
  T="$HOME/.buildtools/selftest"; rm -rf "$T"; mkdir -p "$T"
  export PROJECT_ROOT="$T" CUST=SELF SCOPE=buildtest PTYPE="${PTYPE:-js}"
  bash ./bt-setup.sh new-project || { echo "EXIT=new-project-failed"; exit 1; }
  cd "$T/buildtest"
  if mvn -B -e clean package -DskipTests > "$HERE/bt-verify-mvn.log" 2>&1; then
    grep -E 'BUILD|\.package' "$HERE/bt-verify-mvn.log" | tail -5
    echo "PACKAGES:"; find "$T" -name '*.package' -exec ls -la {} \;
    rm -rf "$T"; echo "EXIT=success"
  else
    grep -E 'ERROR|npm|ERR' "$HERE/bt-verify-mvn.log" | head -40
    echo "EXIT=build-failed (project kept at $T/buildtest)"
    D="$HERE/bt-verify-diag.txt"
    {
      echo "### ls -la"; ls -la
      echo "### find (depth 3, no node_modules)"; find . -maxdepth 3 -not -path '*/node_modules*' | head -60
      for f in package.json pom.xml; do echo "### $f"; cat "$f" 2>/dev/null; done
      echo "### npm config"; npm config get registry; npm config get prefix
      echo "### mvn -X install-node-deps"
      mvn -B -X clean package -DskipTests > "$HERE/bt-verify-mvnX.log" 2>&1
      sed -n '/install-node-deps (default-install-node-deps)/,/BUILD FAILURE/p' "$HERE/bt-verify-mvnX.log" \
        | grep -v -E '^\[DEBUG\]   \(f\)|Imported|Populating|class realm|Included:|Excluded:' | tail -120
      echo "### target tree"; find target -maxdepth 3 2>/dev/null | head -40
      for f in $(find target -maxdepth 3 -name package.json 2>/dev/null); do echo "### $f"; cat "$f"; done
      echo "### latest npm debug log"; L="$(ls -t "$HOME"/.npm/_logs/*.log 2>/dev/null | head -1)"; echo "$L"; tail -80 "$L" 2>/dev/null
    } > "$D" 2>&1
    echo "diagnostics: $D"
  fi
} 2>&1 | tee "$HERE/bt-verify.log"
echo; echo "Finished - you can close this window."
