#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# EXPERIMENTAL native Linux ELF build (Clang/GCC, no llvm-mingw/Wine). Needs
# MKW_EXPERIMENTAL_LINUX_NATIVE in runtime/CMakeLists.txt, turned on below.

# --package zips a movable copy to dist/. Not self-contained - system shared
# libs (SDL3, Vulkan loader, abseil, ...) aren't bundled, see `ldd`.
# --appimage is for real self-containment.
PACKAGE="${PACKAGE:-0}"

# --appimage builds a self-contained .AppImage to dist/ via linuxdeploy,
# fetched into .toolchain/ on first use.
APPIMAGE="${APPIMAGE:-0}"

# --retro also builds Retro Rewind; see build.sh for RETRO_ROOT. The
# format-specific translator outputs (shard graph + Retro Rewind mod) are
# namespaced per target - see ASM_TARGET_TAG below - so this script and
# build.sh no longer clobber each other's copies in a shared checkout.
RETRO="${RETRO:-0}"
RETRO_SKIP_WFC="${RETRO_SKIP_WFC:-0}"

# --install copies each built product into its own self-contained folder
# under $INSTALL_DIR (default ~/.local/share/WiiCompiled/Install): Base/ and,
# with --retro, RetroRewind/. Disc data and the RetroRewind6 pack are copied
# once into $INSTALL_DIR/{DATA,RetroRewind6}, and installed configs point at
# those, so nothing outside $INSTALL_DIR is needed at runtime. It also writes
# menu launchers to ~/.local/share/applications/ plus the icon.
# --install-dir=PATH overrides the location.
INSTALL="${INSTALL:-0}"
INSTALL_DIR="${INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/WiiCompiled/Install}"

# -i / --interactive prompts for the options below instead of taking flags.
# Also the default with no arguments on an interactive terminal.
INTERACTIVE="${INTERACTIVE:-0}"
for arg in "$@"; do
    case "$arg" in
        --retro) RETRO=1 ;;
        --retro-skip-wfc) RETRO=1; RETRO_SKIP_WFC=1 ;;
        --package) PACKAGE=1 ;;
        --appimage) APPIMAGE=1 ;;
        --install) INSTALL=1 ;;
        --install-dir=*) INSTALL=1; INSTALL_DIR="${arg#*=}" ;;
        -i|--interactive) INTERACTIVE=1 ;;
    esac
done

# $1 question, $2 default (y|n). Returns 0 for yes.
prompt_yes_no() {
    local q="$1" def="${2:-n}" ans hint
    case "$def" in [Yy]*) hint="[Y/n]" ;; *) hint="[y/N]" ;; esac
    printf '%s %s ' "$q" "$hint" >&2
    read -r ans || ans=""
    case "${ans:-$def}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

run_interactive() {
    echo "WiiCompiled native Linux build - interactive setup" >&2
    echo "(pass flags to skip: --retro --install --package --appimage)" >&2
    echo >&2

    if prompt_yes_no "Build Retro Rewind as well?" "$([ "$RETRO" = 1 ] && echo y || echo n)"; then
        RETRO=1
    else
        RETRO=0
    fi
    echo >&2

    local default_choice=1
    [ "$INSTALL" = 1 ] && default_choice=2
    [ "$PACKAGE" = 1 ] && default_choice=3
    [ "$APPIMAGE" = 1 ] && default_choice=4
    {
        echo "Output:"
        echo "  1) dev      - build in ./$BUILD_DIR and run it there"
        echo "  2) install  - tidy folders under $INSTALL_DIR, plus a menu entry / icon"
        echo "  3) package  - a movable .zip in ./dist (disc data bundled)"
        echo "  4) appimage - a self-contained .AppImage in ./dist"
        printf 'Choose [1-4] (%s): ' "$default_choice"
    } >&2
    local choice
    read -r choice || choice=""
    PACKAGE=0; APPIMAGE=0; INSTALL=0
    case "${choice:-$default_choice}" in
        1) : ;;
        2) INSTALL=1 ;;
        3) PACKAGE=1 ;;
        4) APPIMAGE=1 ;;
        *) echo "unrecognized choice '$choice' - using dev" >&2 ;;
    esac
    echo >&2

    local summary="dev build in $BUILD_DIR"
    [ "$INSTALL" = 1 ] && summary="install to $INSTALL_DIR (with menu entry)"
    [ "$PACKAGE" = 1 ] && summary="package ./dist/WiiCompiled-linux.zip"
    [ "$APPIMAGE" = 1 ] && summary="AppImage(s) in ./dist"
    [ "$RETRO" = 1 ] && summary="$summary + Retro Rewind"
    echo "==> $summary" >&2
    prompt_yes_no "Proceed?" y || { echo "aborted." >&2; exit 0; }
    echo >&2
}

BUILD_DIR="${BUILD_DIR:-linux-native-build}"

if [ "$INTERACTIVE" = 1 ] || { [ "$#" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; }; then
    run_interactive
fi
RETRO_ROOT="${RETRO_ROOT:-$(pwd)/PulsarPacks/completed/RetroRewind/RetroRewind6}"

# Rough check so a build fails fast instead of running out of space partway
# through. Override with REQUIRED_FREE_GB / REQUIRED_INSTALL_FREE_GB, or set
# SKIP_DISK_CHECK=1 to skip.
SKIP_DISK_CHECK="${SKIP_DISK_CHECK:-0}"
if [ "$SKIP_DISK_CHECK" != "1" ]; then
    build_required_gb=12
    { [ "$RETRO" = "1" ] || [ "$PACKAGE" = "1" ] || [ "$APPIMAGE" = "1" ]; } && build_required_gb=20
    install_required_gb=5
    [ "$RETRO" = "1" ] && install_required_gb=8

    # $1 path, $2 required GB.
    check_free_space() {
        local path="$1" need_gb="$2" avail_gb
        while [ ! -d "$path" ]; do path="$(dirname "$path")"; done
        avail_gb=$(($(df -Pk "$path" | awk 'NR==2 {print $4}') / 1024 / 1024))
        if [ "$avail_gb" -lt "$need_gb" ]; then
            echo "error: only ${avail_gb}GB free at $path (need ~${need_gb}GB); set REQUIRED_FREE_GB/REQUIRED_INSTALL_FREE_GB or SKIP_DISK_CHECK=1" >&2
            exit 1
        fi
    }

    check_free_space "$(pwd)" "${REQUIRED_FREE_GB:-$build_required_gb}"
    [ "$INSTALL" = "1" ] && check_free_space "$INSTALL_DIR" "${REQUIRED_INSTALL_FREE_GB:-$install_required_gb}"
fi

# Translated assembly (.S) blobs use ELF section syntax here and COFF in
# build.sh. Namespace the format-specific translator outputs by target so the
# two scripts stop overwriting each other in one checkout. (Legacy unsuffixed
# generated/build_shards/ and build/mods/retro_rewind_full_cpp/ from older runs
# are now unused - safe to delete. generated/data_sections_init_blobs.S stays
# shared; it is regenerated unconditionally on every build below.)
ASM_TARGET_TAG=linux
RETRO_OUT="build/mods/retro_rewind_full_cpp-$ASM_TARGET_TAG"
SHARDS_DIR="generated/build_shards-$ASM_TARGET_TAG"

PROJECT_MANIFEST="projects/mkwii/recomp.yml"
TRANSLATOR_DLL="translator/src/Translator.Cli/bin/Release/net8.0/Translator.Cli.dll"

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

# Resolve `nodtool` (encounter/nod) for Wii disc extraction: prefer $NODTOOL
# or PATH, else download the pinned prebuilt into .toolchain/ once.
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

# Auto-extract from a local disc image, same as build.sh.
if ! have_assets || { { [ "$PACKAGE" = "1" ] || [ "$APPIMAGE" = "1" ] || [ "$INSTALL" = "1" ]; } && ! have_extracted_data; }; then
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

if ! have_assets; then
    echo "error: missing game files under Assets/" >&2
    verify_sha256 "Assets/main.dol" "$EXPECTED_DOL_SHA256"     || echo "  - Assets/main.dol     (expected sha256 $EXPECTED_DOL_SHA256)" >&2
    verify_sha256 "Assets/StaticR.rel" "$EXPECTED_REL_SHA256"  || echo "  - Assets/StaticR.rel  (expected sha256 $EXPECTED_REL_SHA256)" >&2
    echo "" >&2
    echo "place a clean PAL RMCP01 disc image (ISO/WBFS/RVZ/...) at the repo root and re-run" >&2
    echo "(nodtool is fetched automatically), or extract it yourself:" >&2
    echo "  nodtool extract your-game.iso ./extracted/DATA" >&2
    echo "then copy extracted/DATA/sys/main.dol and extracted/DATA/files/rel/StaticR.rel into Assets/" >&2
    exit 1
fi

# Clang is what this port's been tested with; GCC is allowed but untested.
CXX_COMPILER="${CXX:-}"
if [ -z "$CXX_COMPILER" ]; then
    if command -v clang++ >/dev/null 2>&1; then
        CXX_COMPILER="clang++"
    elif command -v g++ >/dev/null 2>&1; then
        echo "warning: clang++ not found, falling back to g++ (untested for this target)" >&2
        CXX_COMPILER="g++"
    else
        echo "error: no clang++ or g++ found on PATH; set CXX=/path/to/compiler" >&2
        exit 1
    fi
fi
C_COMPILER="${CC:-}"
if [ -z "$C_COMPILER" ]; then
    if command -v clang >/dev/null 2>&1; then
        C_COMPILER="clang"
    elif command -v gcc >/dev/null 2>&1; then
        C_COMPILER="gcc"
    else
        echo "error: no clang or gcc found on PATH; set CC=/path/to/compiler" >&2
        exit 1
    fi
fi

# Check for dotnet (the translator targets net8.0)
if ! command -v dotnet >/dev/null 2>&1; then
    echo "error: dotnet not found on PATH; install the .NET 8 SDK (e.g. the 'dotnet-sdk-8.0'" >&2
    echo "package on Debian/Ubuntu/Fedora, 'dotnet-sdk' on Arch, or https://dotnet.microsoft.com/download/dotnet/8.0)" >&2
    exit 1
fi
if ! dotnet --list-sdks 2>/dev/null | grep -qE '^([8-9]|[1-9][0-9])\.'; then
    echo "error: no .NET 8+ SDK found (the translator targets net8.0); installed SDKs:" >&2
    dotnet --list-sdks 2>&1 | sed 's/^/  /' >&2
    echo "install the .NET 8 SDK (e.g. the 'dotnet-sdk-8.0' package on Debian/Ubuntu/Fedora," >&2
    echo "'dotnet-sdk' on Arch, or https://dotnet.microsoft.com/download/dotnet/8.0)" >&2
    exit 1
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
    # Check the published version and only skip the check when explicitly asked
    # (SKIP_RETRO_UPDATE_CHECK=1) or with an explicit RETRO_FULL_ZIP_URL override
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
        # Replace RETRO_ROOT wholesale so leftovers from an old incremental
        # install can't shadow the full pack.
        rm -rf "$RETRO_ROOT"
        mkdir -p "$(dirname "$RETRO_ROOT")"
        cp -r "$tmp_extract/RetroRewind6" "$RETRO_ROOT"
        rm -rf "$tmp_extract"
    fi
    if [ ! -f "$RETRO_ROOT/Binaries/Code.pul" ]; then
        echo "error: --retro needs a Retro Rewind install with Binaries/Code.pul" >&2
        echo "  place your RetroRewind6 folder at $RETRO_ROOT" >&2
        echo "  or point RETRO_ROOT at an existing one: RETRO_ROOT=/path/to/RetroRewind6 ./build-linux-native.sh --retro" >&2
        exit 1
    fi
    # The manifest's retro-rewind profile always reads Code.pul from here.
    STAGED_PUL="PulsarPacks/completed/RetroRewind/RetroRewind6/Binaries/Code.pul"
    if [ "$(readlink -f "$RETRO_ROOT/Binaries/Code.pul")" != "$(readlink -f "$STAGED_PUL" 2>/dev/null || true)" ]; then
        mkdir -p "$(dirname "$STAGED_PUL")"
        cp -f "$RETRO_ROOT/Binaries/Code.pul" "$STAGED_PUL"
    fi
    PUL_SHA=$(sha256sum "$RETRO_ROOT/Binaries/Code.pul" | cut -d' ' -f1)
fi

# Translate once (or retranslate if this Code.pul is newer); output is
# portable C++ shared with the mingw build.
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

# ELF section syntax for the embedded-data assembly (COFF on the mingw
# build). Always regenerated (cheap).
echo "==> generating data section init (ELF)"
MKW_ASM_OBJECT_FORMAT=elf dotnet "$TRANSLATOR_DLL" generate-data-init --project "$PROJECT_MANIFEST"

if [ "$RETRO" = "1" ]; then
    mkdir -p build/base
    # --translation-output-metadata is required, or the base manifest gets
    # zero function ranges and translate-mod builds Retro Rewind's dispatch
    # tables against an empty base. Regenerated every run (cheap).
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
    MKW_ASM_OBJECT_FORMAT=elf dotnet "$TRANSLATOR_DLL" "${retro_mod_args[@]}"
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
    -DCMAKE_C_COMPILER="$C_COMPILER" \
    -DCMAKE_CXX_COMPILER="$CXX_COMPILER" \
    -DMKW_TRANSLATED_SHARD_MANIFEST="$(pwd)/$SHARDS_DIR/shards.cmake" \
    -DMKW_EXPERIMENTAL_LINUX_NATIVE=ON

cmake --build "$BUILD_DIR"

# Portable config next to the binary, same as build.sh.
touch "$BUILD_DIR/portable.txt"
mkdir -p "$BUILD_DIR/UserData"
CONFIG_FILE="$BUILD_DIR/UserData/Config.toml"
if [ ! -f "$CONFIG_FILE" ]; then
    dvd_root_line='# dvd_root = "/path/to/MarioKartWii/DATA"'
    if [ -d "extracted/DATA/sys" ] && [ -d "extracted/DATA/files" ]; then
        dvd_root_line="dvd_root = \"$(realpath --relative-to="$BUILD_DIR/UserData" "extracted/DATA")\""
    fi
    cat > "$CONFIG_FILE" <<EOF_CONFIG
# WiiCompiled user configuration (generated by build-linux-native.sh)
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
# nand_root = "/path/to/WiiNand"
EOF_CONFIG
    echo "==> wrote portable config: $CONFIG_FILE"
fi

if [ "$RETRO" = "1" ] && ! grep -q '^retro_rewind_root' "$CONFIG_FILE"; then
    retro_root_value="$(realpath --relative-to="$BUILD_DIR/UserData" "$RETRO_ROOT")"
    sed -i "/^\[paths\]/a retro_rewind_root = \"$retro_root_value\"" "$CONFIG_FILE"
    echo "==> set retro_rewind_root in $CONFIG_FILE"
fi

if [ "$INSTALL" = "1" ]; then
    echo ""
    echo "==> installing tidy per-product folders under $INSTALL_DIR"

    # Copy the shared game data once, into $INSTALL_DIR, so the install needs
    # nothing from the repo checkout at runtime.
    dvd_abs=""
    if [ -d "extracted/DATA/sys" ] && [ -d "extracted/DATA/files" ]; then
        echo "    copying disc data -> $INSTALL_DIR/DATA"
        rm -rf "$INSTALL_DIR/DATA"
        mkdir -p "$INSTALL_DIR"
        cp -r "extracted/DATA" "$INSTALL_DIR/DATA"
        dvd_abs="$INSTALL_DIR/DATA"
    else
        echo "    note: extracted/DATA not found - leaving dvd_root commented in the installed config" >&2
    fi

    retro_abs=""
    if [ "$RETRO" = "1" ] && [ -d "$RETRO_ROOT" ]; then
        echo "    copying RetroRewind6 ($(du -sh "$RETRO_ROOT" 2>/dev/null | cut -f1)) -> $INSTALL_DIR/RetroRewind6"
        rm -rf "$INSTALL_DIR/RetroRewind6"
        mkdir -p "$INSTALL_DIR"
        cp -r "$RETRO_ROOT" "$INSTALL_DIR/RetroRewind6"
        retro_abs="$INSTALL_DIR/RetroRewind6"
    fi

    # $1 product folder, $2 binary name, $3 = 1 when this product is Retro Rewind
    install_product() {
        local name="$1" binary="$2" is_retro="$3"
        local dest="$INSTALL_DIR/$name"
        local nand_stash=""
        if [ -d "$dest/UserData/NAND" ]; then
            nand_stash="$(mktemp -d)"
            mv "$dest/UserData/NAND" "$nand_stash/NAND"
        fi
        rm -rf "$dest"
        mkdir -p "$dest/UserData"
        if [ -n "$nand_stash" ]; then
            mv "$nand_stash/NAND" "$dest/UserData/NAND"
            rmdir "$nand_stash"
        fi
        cp -f "$BUILD_DIR/$binary" "$BUILD_DIR/dsp_coef.bin" \
              "$BUILD_DIR/initial_pipeline_cache.db" "$dest/"
        cp -r "$BUILD_DIR/wii_bootstrap" "$dest/wii_bootstrap"
        touch "$dest/portable.txt"
        # Reuse the [video]/[audio]/... sections from the build's config, then
        # re-append [paths] pointing at the data copied into $INSTALL_DIR above.
        sed "/^\[paths\]/,\$d" "$CONFIG_FILE" > "$dest/UserData/Config.toml"
        {
            echo "[paths]"
            if [ -n "$dvd_abs" ]; then
                echo "dvd_root = \"$dvd_abs\""
            else
                echo "# dvd_root = \"/path/to/MarioKartWii/DATA\""
            fi
            if [ "$is_retro" = "1" ] && [ -n "$retro_abs" ]; then
                echo "retro_rewind_root = \"$retro_abs\""
            fi
            echo "# nand_root = \"/path/to/WiiNand\""
        } >> "$dest/UserData/Config.toml"
        echo "    $dest/$binary"
    }

    install_product Base WiiCompiled 0
    if [ "$RETRO" = "1" ]; then
        install_product RetroRewind RetroRewind 1
    fi

    # Menu launcher(s) + icon.
    if [ "$INSTALL" = "1" ]; then
        apps_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
        icons_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
        mkdir -p "$apps_dir" "$icons_dir"
        icon_name=""
        if [ -f runtime/assets/appimage/wiicompiled.png ]; then
            cp -f runtime/assets/appimage/wiicompiled.png "$icons_dir/wiicompiled.png"
            icon_name="wiicompiled"
        fi
        # $1 .desktop basename, $2 Name=, $3 executable path
        write_desktop() {
            local file="$apps_dir/$1.desktop"
            {
                echo "[Desktop Entry]"
                echo "Type=Application"
                echo "Name=$2"
                echo "GenericName=Mario Kart Wii PC Recompiled"
                echo "Comment=Statically recompiled Mario Kart Wii"
                echo "Exec=\"$3\""
                [ -n "$icon_name" ] && echo "Icon=$icon_name"
                echo "Categories=Game;"
                echo "Terminal=false"
            } > "$file"
            echo "    $file"
        }
        write_desktop wiicompiled "WiiCompiled" "$INSTALL_DIR/Base/WiiCompiled"
        if [ "$RETRO" = "1" ]; then
            write_desktop wiicompiled-retrorewind "WiiCompiled Retro Rewind" \
                "$INSTALL_DIR/RetroRewind/RetroRewind"
        fi
        command -v update-desktop-database >/dev/null 2>&1 && \
            update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
    fi
fi

if [ "$PACKAGE" = "1" ] || [ "$APPIMAGE" = "1" ]; then
    if [ ! -d "extracted/DATA/sys" ] || [ ! -d "extracted/DATA/files" ]; then
        echo "error: --package/--appimage need extracted/DATA, which isn't there yet." >&2
        echo "" >&2
        echo "This is your own disc's filesystem (game files, not this project's - see the README's" >&2
        echo "note on that), extracted once so it can be bundled into a movable copy:" >&2
        echo "  1. place a clean PAL RMCP01 disc image (ISO/WBFS/GCZ/CISO/WIA/RVZ) at the repo root" >&2
        echo "  2. re-run this script with the same flags (nodtool is fetched automatically)" >&2
        echo "" >&2
        echo "or extract it yourself:" >&2
        echo "  Dolphin: right-click the game -> Properties -> Filesystem -> Extract Entire Disc" >&2
        echo "           -> point the destination at extracted/DATA" >&2
        echo "  nodtool CLI: nodtool extract your-game.iso ./extracted/DATA" >&2
        echo "then re-run this script with the same flags" >&2
        exit 1
    fi

    # Staged once; --package zips it, --appimage drops it into an AppDir.
    STAGE_DIR="dist/.stage-WiiCompiled-linux"
    echo ""
    echo "==> staging a movable copy at $STAGE_DIR (this could take a while)"
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR/UserData"
    cp -f "$BUILD_DIR/WiiCompiled" "$BUILD_DIR/dsp_coef.bin" "$BUILD_DIR/initial_pipeline_cache.db" "$STAGE_DIR/"
    if [ "$RETRO" = "1" ]; then
        cp -f "$BUILD_DIR/RetroRewind" "$STAGE_DIR/"
    fi
    cp -r "$BUILD_DIR/wii_bootstrap" "$STAGE_DIR/wii_bootstrap"
    touch "$STAGE_DIR/portable.txt"
    cp -r "extracted/DATA" "$STAGE_DIR/DATA"

    stage_paths=('dvd_root = "../DATA"')
    if [ "$RETRO" = "1" ]; then
        echo "==> copying RetroRewind6 ($(du -sh "$RETRO_ROOT" | cut -f1))"
        cp -r "$RETRO_ROOT" "$STAGE_DIR/RetroRewind6"
        stage_paths+=('retro_rewind_root = "../RetroRewind6"')
    fi
    sed "/^\[paths\]/,\$d" "$CONFIG_FILE" > "$STAGE_DIR/UserData/Config.toml"
    { echo "[paths]"; printf '%s\n' "${stage_paths[@]}"; } >> "$STAGE_DIR/UserData/Config.toml"

    if [ "$PACKAGE" = "1" ]; then
        echo "==> zipping $STAGE_DIR"
        rm -rf "dist/WiiCompiled-linux"
        cp -r "$STAGE_DIR" "dist/WiiCompiled-linux"
        rm -f "dist/WiiCompiled-linux.zip"
        (cd dist && zip -rq -1 "WiiCompiled-linux.zip" "WiiCompiled-linux")
        rm -rf "dist/WiiCompiled-linux"
        echo "==> packaged: dist/WiiCompiled-linux.zip ($(du -sh dist/WiiCompiled-linux.zip | cut -f1))"
    fi

    if [ "$APPIMAGE" = "1" ]; then
        echo ""
        echo "==> building AppImage(s)"

        # Bundles the shared libs --package leaves out; fetched once into
        # .toolchain/, same pattern as build.sh's llvm-mingw/cppwinrt.
        LINUXDEPLOY_DIR="$(pwd)/.toolchain/linuxdeploy"
        LINUXDEPLOY="$LINUXDEPLOY_DIR/linuxdeploy-x86_64.AppImage"
        LINUXDEPLOY_PLUGIN="$LINUXDEPLOY_DIR/linuxdeploy-plugin-appimage-x86_64.AppImage"
        if [ ! -x "$LINUXDEPLOY" ] || [ ! -x "$LINUXDEPLOY_PLUGIN" ]; then
            echo "==> fetching linuxdeploy into $LINUXDEPLOY_DIR (first --appimage build only)"
            mkdir -p "$LINUXDEPLOY_DIR"
            curl -L -o "$LINUXDEPLOY" "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage"
            curl -L -o "$LINUXDEPLOY_PLUGIN" "https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/continuous/linuxdeploy-plugin-appimage-x86_64.AppImage"
            chmod +x "$LINUXDEPLOY" "$LINUXDEPLOY_PLUGIN"
        fi

        # AppImages need an icon, checked into version control at this path.
        ICON_FILE="runtime/assets/appimage/wiicompiled.png"
        if [ ! -f "$ICON_FILE" ]; then
            echo "error: --appimage needs an icon at $ICON_FILE (any size) - place one and re-run" >&2
            exit 1
        fi

        export PATH="$LINUXDEPLOY_DIR:$PATH"
        export APPIMAGE_EXTRACT_AND_RUN=1
        mkdir -p dist

        # Each AppImage gets its own fresh AppDir - sharing one made
        # linuxdeploy's appimage plugin clobber the first build's output.
        #
        # $1=output name, $2=binary to run, $3=desktop Name=.
        build_appimage() {
            local out_name="$1" binary="$2" human_name="$3"
            local appdir="dist/.stage-AppDir-$out_name"
            rm -rf "$appdir"
            mkdir -p "$appdir/usr/bin"
            cp -r "$STAGE_DIR/." "$appdir/usr/bin/"
            # Skip portable.txt: it'd put UserData/ inside the read-only
            # squashfs mount. AppRun below redirects writes to $HOME instead.
            rm -f "$appdir/usr/bin/portable.txt"

            # $HERE changes every launch (fresh mount dir), so [paths] is
            # rewritten each run instead of baked in at build time.
            cat > "$appdir/AppRun" <<EOF_APPRUN
#!/bin/sh
set -eu
HERE="\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)"
DATA_HOME="\${XDG_DATA_HOME:-\$HOME/.local/share}/WiiCompiled"
mkdir -p "\$DATA_HOME"
CONFIG="\$DATA_HOME/Config.toml"
if [ ! -f "\$CONFIG" ]; then
    cp "\$HERE/usr/bin/UserData/Config.toml" "\$CONFIG"
fi
sed -i '/^\[paths\]/,\$d' "\$CONFIG"
{
    echo "[paths]"
    echo "dvd_root = \"\$HERE/usr/bin/DATA\""
EOF_APPRUN
            if [ "$RETRO" = "1" ]; then
                cat >> "$appdir/AppRun" <<'EOF_APPRUN'
    echo "retro_rewind_root = \"$DATA_HOME/sdroot/RetroRewind6\""
EOF_APPRUN
            fi
            cat >> "$appdir/AppRun" <<EOF_APPRUN
} >> "\$CONFIG"
EOF_APPRUN
            if [ "$RETRO" = "1" ]; then
                # Retro Rewind saves next to retro_rewind_root's parent, so
                # RetroRewind6/ itself must be a real directory (not a
                # symlink, which weakly_canonical() resolves back to the
                # read-only mount) - symlink its contents instead.
                cat >> "$appdir/AppRun" <<'EOF_APPRUN'
mkdir -p "$DATA_HOME/sdroot/RetroRewind6"
for entry in "$HERE"/usr/bin/RetroRewind6/* "$HERE"/usr/bin/RetroRewind6/.[!.]*; do
    [ -e "$entry" ] || continue
    ln -sfn "$entry" "$DATA_HOME/sdroot/RetroRewind6/$(basename "$entry")"
done
EOF_APPRUN
            fi
            cat >> "$appdir/AppRun" <<EOF_APPRUN
exec "\$HERE/usr/bin/$binary" "\$@"
EOF_APPRUN
            chmod +x "$appdir/AppRun"

            cat > "$appdir/$out_name.desktop" <<EOF_DESKTOP
[Desktop Entry]
Type=Application
Name=$human_name
GenericName=Mario Kart Wii PC Recompiled
Comment=Statically recompiled Mario Kart Wii
Exec=$binary
Icon=wiicompiled
Categories=Game;
Terminal=false
EOF_DESKTOP

            rm -f ./*.AppImage
            "$LINUXDEPLOY" --appdir "$appdir" --executable "$appdir/usr/bin/$binary" \
                --desktop-file "$appdir/$out_name.desktop" --icon-file "$ICON_FILE" --output appimage
            mv -f ./*.AppImage "dist/$out_name-linux-x86_64.AppImage"
            rm -rf "$appdir"
            echo "==> packaged: dist/$out_name-linux-x86_64.AppImage ($(du -sh "dist/$out_name-linux-x86_64.AppImage" | cut -f1))"
        }

        build_appimage WiiCompiled WiiCompiled "WiiCompiled"
        if [ "$RETRO" = "1" ]; then
            build_appimage RetroRewind RetroRewind "WiiCompiled Retro Rewind"
        fi
    fi

    rm -rf "$STAGE_DIR"
fi

echo ""
echo "Build complete! Find it at $BUILD_DIR/WiiCompiled"
if [ "$RETRO" = "1" ]; then
    echo "Retro Rewind build at $BUILD_DIR/RetroRewind"
fi
echo ""
echo "EXPERIMENTAL native Linux build - not the shipped/supported path (build.sh"
echo "produces that)."

if [ "$INSTALL" = "1" ]; then
    echo ""
    echo "Installed: $INSTALL_DIR/Base/WiiCompiled"
    if [ "$RETRO" = "1" ]; then
        echo "       and $INSTALL_DIR/RetroRewind/RetroRewind"
    fi
    echo "Menu launchers written to ${XDG_DATA_HOME:-$HOME/.local/share}/applications/."
    echo "The disc data and RetroRewind6 pack were copied to $INSTALL_DIR/{DATA,RetroRewind6};"
    echo "everything needed at runtime now lives under $INSTALL_DIR."
    echo "Uninstall with ./uninstall-linux-native.sh (pass the same --install-dir= if you used one)."
fi

if [ "$APPIMAGE" = "1" ]; then
    echo ""
    echo "To play: chmod +x dist/WiiCompiled-linux-x86_64.AppImage and run it, anywhere."
    echo "Game data and shared libraries are both bundled - nothing else to install."
    if [ "$RETRO" = "1" ]; then
        echo "Retro Rewind: dist/RetroRewind-linux-x86_64.AppImage, same way."
    fi
elif [ "$PACKAGE" = "1" ]; then
    echo ""
    echo "To play: unzip dist/WiiCompiled-linux.zip anywhere and run ./WiiCompiled inside it."
    echo "Your extracted game data is already bundled (UserData/Config.toml's dvd_root points at"
    echo "the DATA/ folder next to the binary). NOT bundled: the shared libraries it dynamically"
    echo "links (SDL3, the Vulkan loader, abseil, libpng, zlib, ...) - run 'ldd WiiCompiled' to see"
    echo "the full list, and install whichever your target machine is missing."
elif [ "$INSTALL" != "1" ]; then
    echo ""
    echo "To play: run $BUILD_DIR/WiiCompiled as-is. If you move it, take the whole $BUILD_DIR/"
    echo "folder with it (wii_bootstrap/, dsp_coef.bin, initial_pipeline_cache.db,"
    echo "UserData/Config.toml) plus whatever game data/mod folders Config.toml points at."
    echo "Re-run with --package for a movable copy, --install for tidy folders / a menu entry."
fi
