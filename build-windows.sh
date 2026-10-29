#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

BUILD_DIR="${BUILD_DIR:-native-build}"
TOOLCHAIN_DIR="${LLVM_MINGW_DIR:-$(pwd)/.toolchain/llvm-mingw}"
CPPWINRT_DIR="${CPPWINRT_DIR:-$(pwd)/.toolchain/cppwinrt}"
PROJECT_MANIFEST="projects/mkwii/recomp.yml"
TRANSLATOR_DLL="translator/src/Translator.Cli/bin/Release/net8.0/Translator.Cli.dll"

# --retro (or RETRO=1) also builds Retro Rewind. RETRO_ROOT needs
# Binaries/Code.pul, xml/RetroRewind6.xml, and the disc overlay (Race/,
# Language/, ...) directly under it or under files/. Defaults to
# PulsarPacks/completed/RetroRewind/RetroRewind6.
RETRO="${RETRO:-0}"
RETRO_SKIP_WFC="${RETRO_SKIP_WFC:-0}"
# --package (or PACKAGE=1) also zips a self-contained, movable copy to dist/.
PACKAGE="${PACKAGE:-0}"
for arg in "$@"; do
    case "$arg" in
        --retro) RETRO=1 ;;
        --retro-skip-wfc) RETRO=1; RETRO_SKIP_WFC=1 ;;
        --package) PACKAGE=1 ;;
    esac
done
RETRO_ROOT="${RETRO_ROOT:-$(pwd)/PulsarPacks/completed/RetroRewind/RetroRewind6}"

# Translated assembly (.S) blobs use COFF section syntax here and ELF in
# build-linux-native.sh. Namespace the format-specific translator outputs by
# target so the two scripts stop overwriting each other in one checkout.
# (Legacy unsuffixed generated/build_shards/ and build/mods/retro_rewind_full_cpp/
# from older runs are now unused - safe to delete. generated/data_sections_init_blobs.S
# stays shared; it is regenerated unconditionally on every build below.)
ASM_TARGET_TAG=win
RETRO_OUT="build/mods/retro_rewind_full_cpp-$ASM_TARGET_TAG"
SHARDS_DIR="generated/build_shards-$ASM_TARGET_TAG"

EXPECTED_DOL_SHA256="80d18895b39c63bd80f457398bfcbb91b7d16ac116a41a88967e954080155b05"
EXPECTED_REL_SHA256="16d9d146112541fefea701ecb5bc1a496f9d50e4a752fbb5b6778e7c6399f67d"

verify_sha256() {
    [ -f "$1" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]
}

have_assets() {
    verify_sha256 "Assets/main.dol" "$EXPECTED_DOL_SHA256" && verify_sha256 "Assets/StaticR.rel" "$EXPECTED_REL_SHA256"
}

have_extracted_data() {
    [ -d "extracted/DATA/sys" ] && [ -d "extracted/DATA/files" ]
}

NODTOOL_VERSION="${NODTOOL_VERSION:-v2.0.0-alpha.10}"
NODTOOL_DIR="${NODTOOL_DIR:-$(pwd)/.toolchain/nodtool}"

# Resolve `nodtool` (encounter/nod, MIT/Apache-2.0) for Wii disc extraction.
# Prefers $NODTOOL or one on PATH, else downloads the pinned prebuilt into
# .toolchain/ once. Sets $NODTOOL on success; non-zero if it can't be had.
ensure_nodtool() {
    if [ -n "${NODTOOL:-}" ] && [ -x "${NODTOOL:-}" ]; then return 0; fi
    if command -v nodtool >/dev/null 2>&1; then NODTOOL="$(command -v nodtool)"; return 0; fi
    local asset
    case "$(uname -m)" in
        x86_64|amd64)  asset="nodtool-linux-x86_64" ;;
        aarch64|arm64) asset="nodtool-linux-aarch64" ;;
        i686|i386|x86) asset="nodtool-linux-i686" ;;
        *) echo "error: no prebuilt nodtool for $(uname -m); install nodtool and set NODTOOL" >&2; return 1 ;;
    esac
    NODTOOL="$NODTOOL_DIR/$asset"
    if [ ! -x "$NODTOOL" ]; then
        echo "==> fetching nodtool $NODTOOL_VERSION into $NODTOOL_DIR (first disc extract only)" >&2
        mkdir -p "$NODTOOL_DIR"
        if ! curl -fL -o "$NODTOOL.tmp" \
            "https://github.com/encounter/nod/releases/download/$NODTOOL_VERSION/$asset"; then
            rm -f "$NODTOOL.tmp"; echo "error: could not download nodtool" >&2; return 1
        fi
        chmod +x "$NODTOOL.tmp"
        mv -f "$NODTOOL.tmp" "$NODTOOL"
    fi
}

# Auto-extract main.dol/StaticR.rel from a local disc image if Assets/ doesn't
# already hold a verified clean PAL RMCP01 copy, or if --package needs
# extracted/DATA/ too. Accepts whatever nodtool does (ISO, GCM, GCZ, CISO,
# WBFS, WIA, RVZ) sitting at the repo root; set GAME_IMAGE to pick one
# explicitly (path or name) when more than one exists or it lives elsewhere.
if ! have_assets || { [ "$PACKAGE" = "1" ] && ! have_extracted_data; }; then
    if [ -z "${GAME_IMAGE:-}" ]; then
        shopt -s nullglob nocaseglob
        candidates=(*.wbfs *.iso *.gcm *.gcz *.ciso *.wia *.rvz)
        shopt -u nullglob nocaseglob
        if [ "${#candidates[@]}" -eq 1 ]; then
            GAME_IMAGE="${candidates[0]}"
        elif [ "${#candidates[@]}" -gt 1 ]; then
            echo "error: multiple disc images found at the repo root; set GAME_IMAGE=path/to/image" >&2
            printf '  - %s\n' "${candidates[@]}" >&2
            exit 1
        fi
    fi

    if [ -n "${GAME_IMAGE:-}" ] && ensure_nodtool; then
        if ! verify_sha256 "extracted/DATA/sys/main.dol" "$EXPECTED_DOL_SHA256" ||
           ! verify_sha256 "extracted/DATA/files/rel/StaticR.rel" "$EXPECTED_REL_SHA256"; then
            echo "==> extracting $GAME_IMAGE (this only needs to happen once)"
            rm -rf extracted
            "$NODTOOL" extract "$GAME_IMAGE" extracted/DATA -q
        fi
        if verify_sha256 "extracted/DATA/sys/main.dol" "$EXPECTED_DOL_SHA256" &&
           verify_sha256 "extracted/DATA/files/rel/StaticR.rel" "$EXPECTED_REL_SHA256"; then
            mkdir -p Assets
            cp -f extracted/DATA/sys/main.dol Assets/main.dol
            cp -f extracted/DATA/files/rel/StaticR.rel Assets/StaticR.rel
        else
            echo "error: $GAME_IMAGE did not produce a clean PAL RMCP01 main.dol/StaticR.rel (wrong region/revision?)" >&2
        fi
    fi
fi

# files that need to be dumped from PAL RMCP01 disc
if ! have_assets; then
    echo "error: missing game files under Assets/" >&2
    verify_sha256 "Assets/main.dol" "$EXPECTED_DOL_SHA256"     || echo "  - Assets/main.dol     (expected sha256 $EXPECTED_DOL_SHA256)" >&2
    verify_sha256 "Assets/StaticR.rel" "$EXPECTED_REL_SHA256"  || echo "  - Assets/StaticR.rel  (expected sha256 $EXPECTED_REL_SHA256)" >&2
    echo "" >&2
    echo "place a clean PAL RMCP01 disc image (ISO/WBFS/RVZ/...) at the repo root and re-run" >&2
    echo "(nodtool is fetched automatically), or extract it yourself:" >&2
    echo "  Dolphin: right-click the game -> Properties -> Filesystem -> Extract Entire Disc" >&2
    echo "  or CLI:  nodtool extract your-game.iso ./extracted/DATA" >&2
    echo "then copy extracted/DATA/sys/main.dol and extracted/DATA/files/rel/StaticR.rel into Assets/" >&2
    echo "verify with: sha256sum Assets/main.dol Assets/StaticR.rel" >&2
    exit 1
fi

# Fetch llvm-mingw locally if it isn't already present
if [ ! -x "$TOOLCHAIN_DIR/bin/x86_64-w64-mingw32-clang++" ]; then
    echo "==> fetching llvm-mingw (not found at $TOOLCHAIN_DIR)"
    asset_url=$(curl -sL https://api.github.com/repos/mstorsjo/llvm-mingw/releases/latest \
        | jq -r '.assets[].browser_download_url' \
        | grep -E 'ucrt-ubuntu-[0-9.]+-x86_64\.tar\.xz$' \
        | head -n1)
    if [ -z "$asset_url" ]; then
        echo "error: could not find an llvm-mingw ucrt/ubuntu/x86_64 release asset" >&2
        exit 1
    fi
    tmp_archive="$(mktemp --suffix=.tar.xz)"
    tmp_extract="$(mktemp -d)"
    curl -sL -o "$tmp_archive" "$asset_url"
    tar -xf "$tmp_archive" -C "$tmp_extract"
    rm -f "$tmp_archive"
    mkdir -p "$(dirname "$TOOLCHAIN_DIR")"
    rm -rf "$TOOLCHAIN_DIR"
    mv "$(find "$tmp_extract" -mindepth 1 -maxdepth 1 -type d | head -n1)" "$TOOLCHAIN_DIR"
    rm -rf "$tmp_extract"
fi

# music_attenuation.cpp needs C++/WinRT headers llvm-mingw doesn't ship;
# fetch the community mingw-w64-cppwinrt project's prebuilt set.
if [ ! -f "$CPPWINRT_DIR/winrt/base.h" ]; then
    echo "==> fetching mingw-w64-cppwinrt headers (not found at $CPPWINRT_DIR)"
    # take the newest entry from the full release list
    asset_url=$(curl -sL https://api.github.com/repos/alvinhochun/mingw-w64-cppwinrt/releases \
        | jq -r '[.[] | select(.assets[].name | test("-headers\\.tar\\.gz$"))][0].assets[].browser_download_url' \
        | grep -E '\-headers\.tar\.gz$' \
        | head -n1)
    if [ -z "$asset_url" ]; then
        echo "error: could not find a mingw-w64-cppwinrt headers release asset" >&2
        exit 1
    fi
    tmp_archive="$(mktemp --suffix=.tar.gz)"
    tmp_extract="$(mktemp -d)"
    curl -sL -o "$tmp_archive" "$asset_url"
    tar -xzf "$tmp_archive" -C "$tmp_extract"
    rm -f "$tmp_archive"
    cppwinrt_src="$(dirname "$(dirname "$(find "$tmp_extract" -type f -path '*/winrt/base.h' | head -n1)")")"
    if [ -z "$cppwinrt_src" ] || [ ! -f "$cppwinrt_src/winrt/base.h" ]; then
        echo "error: mingw-w64-cppwinrt archive did not contain winrt/base.h" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$CPPWINRT_DIR")"
    rm -rf "$CPPWINRT_DIR"
    mv "$cppwinrt_src" "$CPPWINRT_DIR"
    rm -rf "$tmp_extract"
fi

# Always rebuild the translator; dotnet's incremental build is a no-op when
# translator/ is unchanged, and this avoids using a stale DLL after a git pull.
echo "==> building translator (incremental)"
dotnet build translator/src/Translator.Cli/Translator.Cli.csproj -c Release --nologo

# Fingerprint the build so a changed translator forces a re-translate below,
# the same way a new Code.pul does.
TRANSLATOR_ID=$(find translator/src/Translator.Cli/bin/Release/net8.0 -name '*.dll' -type f \
    -exec sha256sum {} + | sort | sha256sum | cut -d' ' -f1)
TRANSLATOR_STAMP="generated/.translator-build-id"

PUL_SHA=""
if [ "$RETRO" = "1" ]; then
    NEED_RETRO_DOWNLOAD=0
    if [ ! -f "$RETRO_ROOT/Binaries/Code.pul" ]; then
        NEED_RETRO_DOWNLOAD=1
    elif [ -n "${RETRO_FULL_ZIP_URL:-}" ]; then
        NEED_RETRO_DOWNLOAD=1
    elif [ "${SKIP_RETRO_UPDATE_CHECK:-0}" != "1" ]; then
        rr_latest_version="$(curl -fsSL "https://update.rwfc.net/RetroRewind/RetroRewindVersion.txt" \
            | grep -oE '^[0-9]+(\.[0-9]+)+' | tail -n1)"
        rr_local_version=""
        [ -f "$RETRO_ROOT/version.txt" ] && rr_local_version="$(tr -d '[:space:]' < "$RETRO_ROOT/version.txt")"
        if [ -n "$rr_latest_version" ] && [ "$rr_latest_version" != "$rr_local_version" ]; then
            echo "==> Retro Rewind $rr_local_version is outdated (latest: $rr_latest_version)"
            NEED_RETRO_DOWNLOAD=1
        fi
    fi

    if [ "$NEED_RETRO_DOWNLOAD" = "1" ]; then
        RETRO_FULL_ZIP_URL="${RETRO_FULL_ZIP_URL:-https://update.rwfc.net/RetroRewind/zip/RetroRewind.zip}"
        echo "==> downloading the full Retro Rewind pack"
        echo "    $RETRO_FULL_ZIP_URL"
        tmp_archive="$(mktemp --suffix=.zip)"
        tmp_extract="$(mktemp -d)"
        curl -fL -o "$tmp_archive" "$RETRO_FULL_ZIP_URL"
        unzip -q "$tmp_archive" "RetroRewind6/*" -d "$tmp_extract"
        rm -f "$tmp_archive"
        if [ ! -f "$tmp_extract/RetroRewind6/Binaries/Code.pul" ]; then
            echo "error: downloaded Retro Rewind archive did not contain RetroRewind6/Binaries/Code.pul" >&2
            rm -rf "$tmp_extract"
            exit 1
        fi
        # This branch only runs when RETRO_ROOT has no Code.pul, i.e. it is
        # missing or a stale partial tree - replace it wholesale so leftovers
        # from an old incremental RetroRewind.zip can't shadow the full pack.
        rm -rf "$RETRO_ROOT"
        mkdir -p "$(dirname "$RETRO_ROOT")"
        cp -r "$tmp_extract/RetroRewind6" "$RETRO_ROOT"
        rm -rf "$tmp_extract"
    fi
    if [ ! -f "$RETRO_ROOT/Binaries/Code.pul" ]; then
        echo "error: --retro needs a Retro Rewind install with Binaries/Code.pul" >&2
        echo "  place your RetroRewind6 folder at $RETRO_ROOT" >&2
        echo "  or point RETRO_ROOT at an existing one: RETRO_ROOT=/path/to/RetroRewind6 ./build.sh --retro" >&2
        exit 1
    fi
    # The project manifest's retro-rewind profile always reads Code.pul from
    # PulsarPacks/completed/RetroRewind/RetroRewind6/Binaries
    STAGED_PUL="PulsarPacks/completed/RetroRewind/RetroRewind6/Binaries/Code.pul"
    if [ "$(readlink -f "$RETRO_ROOT/Binaries/Code.pul")" != "$(readlink -f "$STAGED_PUL" 2>/dev/null || true)" ]; then
        mkdir -p "$(dirname "$STAGED_PUL")"
        cp -f "$RETRO_ROOT/Binaries/Code.pul" "$STAGED_PUL"
    fi
    PUL_SHA=$(sha256sum "$RETRO_ROOT/Binaries/Code.pul" | cut -d' ' -f1)
fi

# Translate the DOL/REL into generated/ if that hasn't been done yet, or (for
# a Retro Rewind build) if the existing translation predates this Code.pul.
NEED_BASE_TRANSLATE=0
if [ ! -f "generated/base_translation_output.json" ]; then
    NEED_BASE_TRANSLATE=1
elif [ "$RETRO" = "1" ] && ! grep -q "\"codePulSha256\":\"$PUL_SHA\"" generated/base_translation_output.json; then
    echo "==> base translation predates this Code.pul; retranslating"
    NEED_BASE_TRANSLATE=1
elif [ ! -f "$TRANSLATOR_STAMP" ] || [ "$(cat "$TRANSLATOR_STAMP" 2>/dev/null)" != "$TRANSLATOR_ID" ]; then
    echo "==> translator changed since the last translation; retranslating"
    NEED_BASE_TRANSLATE=1
fi

if [ "$NEED_BASE_TRANSLATE" = "1" ]; then
    echo "==> translating Assets/main.dol"
    entry_addr=$(grep -A1 '^\s*entry_points:' "$PROJECT_MANIFEST" | tail -n1 | grep -oE '0x[0-9A-Fa-f]+')
    dotnet "$TRANSLATOR_DLL" translate-recursive "$entry_addr" --project "$PROJECT_MANIFEST" \
        --output-metadata generated/base_translation_output.json \
        --production-source-bundle generated/base_translation_sources.bin
    mkdir -p generated && printf '%s\n' "$TRANSLATOR_ID" > "$TRANSLATOR_STAMP"
fi

dotnet "$TRANSLATOR_DLL" generate-data-init --project "$PROJECT_MANIFEST"

if [ "$RETRO" = "1" ]; then
    mkdir -p build/base
    # Must pass --translation-output-metadata: without it the base manifest is
    # written with zero function ranges, and translate-mod then builds Retro
    # Rewind's dispatch/page tables against an empty base - the pause menu ends
    # up resolving a page index to a garbage pointer and crashes on Activate.
    # Regenerated every run (cheap) so a stale/empty manifest can't linger.
    dotnet "$TRANSLATOR_DLL" emit-base-manifest --project "$PROJECT_MANIFEST" \
        --translation-output-metadata generated/base_translation_output.json \
        --region P
    echo "==> translating Retro Rewind Code.pul"
    retro_mod_args=(translate-mod --project "$PROJECT_MANIFEST" --profile retro-rewind
        --base-manifest build/base/mkwii_base_manifest.json
        --base-translation-output-metadata generated/base_translation_output.json
        --code-pul "$RETRO_ROOT/Binaries/Code.pul" --mod-root "$RETRO_ROOT" --mod-name "Retro Rewind"
        --region P --out "$RETRO_OUT" --emit-cpp)
    if [ "$RETRO_SKIP_WFC" = "1" ]; then
        retro_mod_args+=(--skip-retro-wfc)
    fi
    dotnet "$TRANSLATOR_DLL" "${retro_mod_args[@]}"
fi

NEED_SHARDS=0
if [ ! -f "$SHARDS_DIR/shards.cmake" ]; then
    NEED_SHARDS=1
elif [ "$RETRO" = "1" ] && ! grep -q "MKW_HAVE_RETRO_REWIND_SHARDS ON" "$SHARDS_DIR/shards.cmake"; then
    NEED_SHARDS=1
elif [ "$NEED_BASE_TRANSLATE" = "1" ]; then
    # base/mod translation was just redone (new Code.pul or translator), so the
    # shards generated from it are stale even though shards.cmake still exists.
    NEED_SHARDS=1
elif [ "generated/base_translation_output.json" -nt "$SHARDS_DIR/shards.cmake" ]; then
    # or a previous run translated but never got to emitting shards.
    NEED_SHARDS=1
fi

if [ "$NEED_SHARDS" = "1" ]; then
    shard_args=(emit-build-shards --project "$PROJECT_MANIFEST" --out "$SHARDS_DIR")
    if [ "$RETRO" = "1" ]; then
        shard_args+=(--resolved-profile "$RETRO_OUT/resolved_dispatch_profile.json" --retro-cpp-dir "$RETRO_OUT/cpp")
    fi
    dotnet "$TRANSLATOR_DLL" "${shard_args[@]}"
fi

cmake -S runtime -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_C_COMPILER="$TOOLCHAIN_DIR/bin/x86_64-w64-mingw32-clang" \
    -DCMAKE_CXX_COMPILER="$TOOLCHAIN_DIR/bin/x86_64-w64-mingw32-clang++" \
    -DCMAKE_RC_COMPILER="$TOOLCHAIN_DIR/bin/x86_64-w64-mingw32-windres" \
    -DCMAKE_FIND_ROOT_PATH="$TOOLCHAIN_DIR/x86_64-w64-mingw32" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    -DAURORA_DAWN_PROVIDER=package \
    -DMKW_TRANSLATED_SHARD_MANIFEST="$(pwd)/$SHARDS_DIR/shards.cmake" \
    -DMKW_CPPWINRT_INCLUDE_DIR="$CPPWINRT_DIR"

cmake --build "$BUILD_DIR"

# portable.txt makes $BUILD_DIR/UserData the config location instead of
# %LOCALAPPDATA%\WiiCompiled (or the Wine-prefix equivalent).
mkdir -p "$BUILD_DIR/UserData"
touch "$BUILD_DIR/portable.txt"
CONFIG_FILE="$BUILD_DIR/UserData/Config.toml"
if [ ! -f "$CONFIG_FILE" ]; then
    dvd_root_line='# dvd_root = "D:/MarioKartWii/DATA"'
    if [ -d "extracted/DATA/sys" ] && [ -d "extracted/DATA/files" ]; then
        dvd_root_line="dvd_root = \"$(realpath --relative-to="$BUILD_DIR/UserData" "extracted/DATA")\""
    fi
    cat > "$CONFIG_FILE" <<EOF_CONFIG
# WiiCompiled user configuration (generated by build.sh)
# Set paths.dvd_root to an extracted Mario Kart Wii DATA directory.

[video]
widescreen = true
resolution_multiplier = 1.0
frame_interpolation_fps = 0
display_mode = "windowed"
graphics_api = "auto"
skip_unready_pipelines = true
disable_copy_filter = true
show_fps = true
texture_replacements = true
texture_dumps = false

[audio]
volume = 1.0
music_volume = 1.0
sound_effects_volume = 1.0
ui_volume = 1.0
voices_volume = 1.0
muted = false
attenuate_music_when_media_plays = false
mix_worker = true

[controller]
rumble = true
wii_remotes = true
wii_continuous_scan = false
# wii_accel_offset_x = 0.0
# wii_accel_offset_y = 0.0
# wii_accel_offset_z = 0.0
# wii_accel_trace = false

[network]
enabled = true

[paths]
$dvd_root_line
# nand_root = "D:/WiiNand"
# retro_rewind_root = "D:/RetroRewind/RetroRewind6"
# overlay_roots = ["D:/RetroRewind"]
EOF_CONFIG
    echo "==> wrote portable config: $CONFIG_FILE"
fi

if [ "$RETRO" = "1" ] && ! grep -q '^retro_rewind_root' "$CONFIG_FILE"; then
    retro_root_value="$(realpath --relative-to="$BUILD_DIR/UserData" "$RETRO_ROOT")"
    sed -i "/^\[paths\]/a retro_rewind_root = \"$retro_root_value\"" "$CONFIG_FILE"
    echo "==> set retro_rewind_root in $CONFIG_FILE"
fi

if [ "$PACKAGE" = "1" ]; then
    if [ ! -d "extracted/DATA/sys" ] || [ ! -d "extracted/DATA/files" ]; then
        echo "error: --package needs extracted/DATA, which isn't there yet." >&2
        echo "" >&2
        echo "This is your own disc's filesystem (game files, not this project's - see the README's" >&2
        echo "note on that), extracted once so --package can bundle it into a self-contained copy:" >&2
        echo "  1. place a clean PAL RMCP01 disc image (ISO/WBFS/GCZ/CISO/WIA/RVZ) at the repo root" >&2
        echo "  2. re-run: ./build.sh --package  (nodtool is fetched automatically to extract it)" >&2
        echo "" >&2
        echo "or extract it yourself:" >&2
        echo "  Dolphin: right-click the game -> Properties -> Filesystem -> Extract Entire Disc" >&2
        echo "           -> point the destination at extracted/DATA" >&2
        echo "  nodtool CLI: nodtool extract your-game.iso ./extracted/DATA" >&2
        echo "then re-run: ./build.sh --package" >&2
        exit 1
    fi
    PACKAGE_DIR="dist/WiiCompiled"
    echo ""
    echo "==> packaging a portable copy at $PACKAGE_DIR (this could takes a while)"
    rm -rf "$PACKAGE_DIR"
    mkdir -p "$PACKAGE_DIR/UserData"
    cp -f "$BUILD_DIR"/*.exe "$BUILD_DIR"/*.dll "$BUILD_DIR/dsp_coef.bin" "$BUILD_DIR/initial_pipeline_cache.db" "$PACKAGE_DIR/"
    cp -r "$BUILD_DIR/wii_bootstrap" "$PACKAGE_DIR/wii_bootstrap"
    touch "$PACKAGE_DIR/portable.txt"
    cp -r "extracted/DATA" "$PACKAGE_DIR/DATA"

    package_paths=('dvd_root = "../DATA"')
    if [ "$RETRO" = "1" ]; then
        echo "==> copying RetroRewind6 ($(du -sh "$RETRO_ROOT" | cut -f1))"
        cp -r "$RETRO_ROOT" "$PACKAGE_DIR/RetroRewind6"
        package_paths+=('retro_rewind_root = "../RetroRewind6"')
    fi
    sed "/^\[paths\]/,\$d" "$CONFIG_FILE" > "$PACKAGE_DIR/UserData/Config.toml"
    { echo "[paths]"; printf '%s\n' "${package_paths[@]}"; } >> "$PACKAGE_DIR/UserData/Config.toml"

    echo "==> zipping $PACKAGE_DIR"
    rm -f "dist/WiiCompiled.zip"
    (cd dist && zip -rq -1 "WiiCompiled.zip" "WiiCompiled")
    rm -rf "$PACKAGE_DIR"
    echo "==> packaged: dist/WiiCompiled.zip ($(du -sh dist/WiiCompiled.zip | cut -f1))"
fi

echo "Build complete! Find it at $BUILD_DIR/WiiCompiled.exe"
if [ "$RETRO" = "1" ]; then
    echo "Retro Rewind build at $BUILD_DIR/RetroRewind.exe"
fi

if [ "$PACKAGE" = "1" ]; then
    echo ""
    echo "To play: unzip dist/WiiCompiled.zip anywhere and run WiiCompiled.exe inside it."
    echo "Your extracted game data is already bundled (UserData/Config.toml's dvd_root points at"
    echo "the DATA/ folder next to the exe), so it's ready to go as-is - no extra setup needed."
else
    echo ""
    echo "To play: run $BUILD_DIR/WiiCompiled.exe as-is. If you move it, take the whole $BUILD_DIR/"
    echo "folder with it (DLLs, wii_bootstrap/, dsp_coef.bin, initial_pipeline_cache.db,"
    echo "UserData/Config.toml) plus whatever game data/mod folders Config.toml points at."
    echo "Re-run with --package for a single self-contained, movable copy instead."
fi
