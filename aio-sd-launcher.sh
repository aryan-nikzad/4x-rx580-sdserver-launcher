#!/bin/bash

# ==========================================================
# AIO Stable Diffusion / sd-server launcher
#
# Flow: choose variety (zimage/sdxl/flux/sd35/sd15)
#       -> choose exact model within that variety
#       -> choose config preset (FAST / MIDDLE / HIGH)
#       -> launch sd-server
# ==========================================================

# ==========================================================
# USER CONFIG
# ==========================================================

CONFIG_FILE="./sd-models.conf"

# sd-server binary location
SD_SERVER="./sd-master-de298c2-bin-Linux-Ubuntu-24.04-x86_64-vulkan/sd-server"

# Base model folder
MODELS_DIR="./models"

# GPU wake delay
WAKE_DELAY=5

PIDS=()


# ==========================================================
# Load model config
# ==========================================================

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found:"
    echo "$CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

if [[ ${#MODEL_NAMES[@]} -eq 0 ]]; then
    echo "ERROR: No models found in config."
    exit 1
fi

if [[ ! -x "$SD_SERVER" ]]; then
    echo "WARNING: sd-server not found or not executable at:"
    echo "$SD_SERVER"
    echo "(edit SD_SERVER at the top of this script if the path is wrong)"
fi


# ==========================================================
# Config preset lookup
#
# The actual --steps/--width/--height/--cfg-scale values live in
# sd-models.conf (CONFIG_FLAGS associative array), keyed "family:mode".
# This is just a lookup with a safe fallback if a combo isn't defined.
# ==========================================================

get_config_flags()
{
    local FAMILY="$1"
    local MODE="$2"
    local KEY="${FAMILY}:${MODE}"

    if [[ -n "${CONFIG_FLAGS[$KEY]+set}" ]]
    then
        echo "${CONFIG_FLAGS[$KEY]}"
    else
        echo ""
    fi
}


# ==========================================================
# Cleanup
# ==========================================================

cleanup_monitors()
{
    echo
    echo "Stopping radeontop monitors..."

    pkill -f "radeontop -b 3" 2>/dev/null
    pkill -f "radeontop -b 4" 2>/dev/null
    pkill -f "radeontop -b 5" 2>/dev/null
    pkill -f "radeontop -b 6" 2>/dev/null

    for pid in "${PIDS[@]}"
    do
        if kill -0 "$pid" 2>/dev/null
        then
            kill "$pid" 2>/dev/null
        fi
    done

    PIDS=()
}

cleanup()
{
    cleanup_monitors
}

trap cleanup EXIT INT TERM


# ==========================================================
# Start GPU monitors
# ==========================================================

start_radeon_monitors()
{
    cleanup_monitors

    echo
    echo "Starting radeontop monitors..."

    for gpu in 3 4 5 6
    do
        gnome-terminal \
        --title="RADEON GPU$gpu" \
        -- bash -c "exec radeontop -b $gpu" &

        PIDS+=("$!")
    done

    echo "RADEON monitors started."
}


# ==========================================================
# STEP 1: choose model variety (family)
# Builds the list of unique families in the order they first appear
# in MODEL_FAMILY, and returns the chosen family via echo.
# ==========================================================

choose_family()
{
    local -a FAMILIES=()
    local f

    for f in "${MODEL_FAMILY[@]}"
    do
        local seen=false
        for existing in "${FAMILIES[@]}"; do
            [[ "$existing" == "$f" ]] && seen=true && break
        done
        [[ "$seen" == false ]] && FAMILIES+=("$f")
    done

    echo >&2
    echo "======================================" >&2
    echo "  STEP 1: Choose model variety" >&2
    echo "======================================" >&2

    for i in "${!FAMILIES[@]}"
    do
        echo "  $((i+1))) ${FAMILIES[$i]}" >&2
    done

    echo >&2
    local CHOICE
    read -r -p "Variety: " CHOICE >&2

    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#FAMILIES[@]} ))
    then
        echo "Invalid choice." >&2
        echo ""
        return
    fi

    echo "${FAMILIES[$((CHOICE-1))]}"
}


# ==========================================================
# STEP 2: choose exact model within the chosen family
# Returns the GLOBAL MODEL_NAMES index via echo.
# ==========================================================

choose_model()
{
    local FAMILY="$1"
    local -a INDEXES=()
    local i

    for i in "${!MODEL_NAMES[@]}"
    do
        if [[ "${MODEL_FAMILY[$i]}" == "$FAMILY" ]]
        then
            INDEXES+=("$i")
        fi
    done

    if [[ ${#INDEXES[@]} -eq 0 ]]; then
        echo "No models found for variety '$FAMILY'." >&2
        echo "-1"
        return
    fi

    echo >&2
    echo "======================================" >&2
    echo "  STEP 2: Choose exact model ($FAMILY)" >&2
    echo "======================================" >&2

    for n in "${!INDEXES[@]}"
    do
        local idx="${INDEXES[$n]}"
        if [[ -n "${MODEL_DESCRIPTION[$idx]}" ]]
        then
            echo "  $((n+1))) ${MODEL_NAMES[$idx]} - ${MODEL_DESCRIPTION[$idx]}" >&2
        else
            echo "  $((n+1))) ${MODEL_NAMES[$idx]}" >&2
        fi
    done

    echo >&2
    local CHOICE
    read -r -p "Model: " CHOICE >&2

    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#INDEXES[@]} ))
    then
        echo "Invalid choice." >&2
        echo "-1"
        return
    fi

    echo "${INDEXES[$((CHOICE-1))]}"
}


# ==========================================================
# STEP 3: choose config preset (FAST / MIDDLE / HIGH)
# Returns the mode string via echo.
# ==========================================================

choose_config_mode()
{
    local FAMILY="$1"
    local -a MODES=("DRAFT" "FAST" "MIDDLE" "HIGH" "MAX")

    echo >&2
    echo "======================================" >&2
    echo "  STEP 3: Choose config" >&2
    echo "======================================" >&2

    for m in "${!MODES[@]}"
    do
        local key="${FAMILY}:${MODES[$m]}"
        local flags="${CONFIG_FLAGS[$key]}"
        echo "  $((m+1))) ${MODES[$m]}   ($flags)" >&2
    done

    echo >&2
    local CHOICE
    read -r -p "Config: " CHOICE >&2

    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#MODES[@]} ))
    then
        echo "Invalid choice, defaulting to FAST." >&2
        echo "FAST"
        return
    fi

    echo "${MODES[$((CHOICE-1))]}"
}


# ==========================================================
# Launch sd-server
# ==========================================================

launch_model()
{
    local INDEX=$1
    local MODE=$2

    MODEL="${MODEL_NAMES[$INDEX]}"
    ARGS="${MODEL_ARGS[$INDEX]}"
    ENVIRONMENT="${MODEL_ENV[$INDEX]}"
    FAMILY="${MODEL_FAMILY[$INDEX]}"

    local PRESET_FLAGS
    PRESET_FLAGS=$(get_config_flags "$FAMILY" "$MODE")

    echo
    echo "======================================"
    echo "Starting:"
    echo "$MODEL"
    echo "Config: $MODE ($PRESET_FLAGS)"
    echo "======================================"

    start_radeon_monitors

    echo
    echo "Waiting ${WAKE_DELAY}s for GPUs..."
    sleep "$WAKE_DELAY"

    echo
    echo "Launching sd-server..."

    if [[ -n "$ENVIRONMENT" ]]
    then
        eval "$ENVIRONMENT" \
        systemd-run --user --scope \
        -p MemoryMax=8G \
        -p OOMPolicy=stop \
        -E RADV_PERFTEST=nogttspill \
        "$SD_SERVER" \
        $ARGS \
        $PRESET_FLAGS
    else
        systemd-run --user --scope \
        -p MemoryMax=8G \
        -p OOMPolicy=stop \
        -E RADV_PERFTEST=nogttspill \
        "$SD_SERVER" \
        $ARGS \
        $PRESET_FLAGS
    fi

    EXIT_CODE=$?

    echo
    echo "sd-server exited with code: $EXIT_CODE"

    cleanup_monitors
}


# ==========================================================
# MAIN LOOP
# ==========================================================

while true
do
    clear
    echo "======================================"
    echo "         AIO SD IMAGE LAUNCHER"
    echo "======================================"
    echo
    echo "1) Launch a model"
    echo "0) Exit"
    echo

    read -r -p "Choice: " TOP_CHOICE

    case "$TOP_CHOICE" in

        1)
            FAMILY=$(choose_family)
            if [[ -z "$FAMILY" ]]; then
                sleep 1
                continue
            fi

            MODEL_INDEX=$(choose_model "$FAMILY")
            if [[ "$MODEL_INDEX" == "-1" ]]; then
                sleep 1
                continue
            fi

            MODE=$(choose_config_mode "$FAMILY")

            launch_model "$MODEL_INDEX" "$MODE"

            echo
            read -r -p "Press Enter to return to menu"
            ;;

        0)
            exit 0
            ;;

        *)
            echo "Invalid choice"
            sleep 1
            ;;

    esac

done
