#!/bin/bash

# ==========================================================
# AIO Stable Diffusion / sd-server launcher
#
# Flow: choose variety (zimage/sdxl/flux/sd35/sd15)
#       -> choose exact model within that variety
#       -> choose config preset (FAST / MIDDLE / HIGH)
#       -> launch sd-server
#
# Top menu now offers:
#   - one entry per PRESET defined in sd-models.conf (auto-answers
#     the variety/model/config prompts below)
#   - "Manual" (the original interactive flow)
#   - "Exit"
# ==========================================================

# ==========================================================
# USER CONFIG
# ==========================================================

CONFIG_FILE="./sd-models-pro.conf"

# sd-server binary location
SD_SERVER="./sd-master-de298c2-bin-Linux-Ubuntu-24.04-x86_64-vulkan/sd-server"

# Base model folder
MODELS_DIR="./models"

# GPU wake delay
WAKE_DELAY=5

PIDS=()

# Queue of "typed" answers used to auto-drive choose_family / choose_model /
# choose_config_mode when a preset is picked. Empty = ask interactively
# (this is what "Manual" uses).
ANSWER_QUEUE=()


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

# PRESET_NAMES / PRESET_ANSWERS are optional - default to empty so the
# script still works fine if sd-models.conf doesn't define any presets.
if [[ -z "${PRESET_NAMES+set}" ]]; then
    PRESET_NAMES=()
fi
if [[ -z "${PRESET_ANSWERS+set}" ]]; then
    PRESET_ANSWERS=()
fi

if [[ ${#PRESET_NAMES[@]} -ne ${#PRESET_ANSWERS[@]} ]]; then
    echo "WARNING: PRESET_NAMES and PRESET_ANSWERS have different lengths in $CONFIG_FILE."
    echo "Presets will be disabled until this is fixed."
    PRESET_NAMES=()
    PRESET_ANSWERS=()
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
# Answer source: either the next queued preset digit, or a real
# interactive prompt. Every place that used to call `read -r -p ...`
# for the variety/model/config choices now goes through here, so
# "Manual" and "presets" share 100% of the same selection logic.
#
# IMPORTANT: this sets the global GET_INPUT_RESULT instead of
# echoing/returning a value. It must be called directly (never via
# `$(get_input ...)`), because command substitution forks a subshell -
# the ANSWER_QUEUE="${ANSWER_QUEUE[@]:1}" shift below would then be
# lost the moment that subshell exits, and the same queued digit
# would get re-read forever instead of advancing.
# ==========================================================

get_input()
{
    local PROMPT="$1"

    if [[ ${#ANSWER_QUEUE[@]} -gt 0 ]]
    then
        GET_INPUT_RESULT="${ANSWER_QUEUE[0]}"
        ANSWER_QUEUE=("${ANSWER_QUEUE[@]:1}")
        echo "${PROMPT}${GET_INPUT_RESULT}   (auto, from preset)" >&2
    else
        read -r -p "$PROMPT" GET_INPUT_RESULT
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
# in MODEL_FAMILY, and sets the global CHOSEN_FAMILY (empty on
# invalid/aborted choice). Called directly - NOT via $(...), see the
# note on get_input above.
# ==========================================================

choose_family()
{
    local -a FAMILIES=()
    local f

    CHOSEN_FAMILY=""

    for f in "${MODEL_FAMILY[@]}"
    do
        local seen=false
        for existing in "${FAMILIES[@]}"; do
            [[ "$existing" == "$f" ]] && seen=true && break
        done
        [[ "$seen" == false ]] && FAMILIES+=("$f")
    done

    echo
    echo "======================================"
    echo "  STEP 1: Choose model variety"
    echo "======================================"

    for i in "${!FAMILIES[@]}"
    do
        echo "  $((i+1))) ${FAMILIES[$i]}"
    done

    echo
    get_input "Variety: "
    local CHOICE="$GET_INPUT_RESULT"

    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#FAMILIES[@]} ))
    then
        echo "Invalid choice."
        return
    fi

    CHOSEN_FAMILY="${FAMILIES[$((CHOICE-1))]}"
}


# ==========================================================
# STEP 2: choose exact model within the chosen family
# Sets the global CHOSEN_MODEL_INDEX (the index into MODEL_NAMES),
# or "-1" on invalid/aborted choice. Called directly - NOT via $(...).
# ==========================================================

choose_model()
{
    local FAMILY="$1"
    local -a INDEXES=()
    local i

    CHOSEN_MODEL_INDEX="-1"

    for i in "${!MODEL_NAMES[@]}"
    do
        if [[ "${MODEL_FAMILY[$i]}" == "$FAMILY" ]]
        then
            INDEXES+=("$i")
        fi
    done

    if [[ ${#INDEXES[@]} -eq 0 ]]; then
        echo "No models found for variety '$FAMILY'."
        return
    fi

    echo
    echo "======================================"
    echo "  STEP 2: Choose exact model ($FAMILY)"
    echo "======================================"

    for n in "${!INDEXES[@]}"
    do
        local idx="${INDEXES[$n]}"
        if [[ -n "${MODEL_DESCRIPTION[$idx]}" ]]
        then
            echo "  $((n+1))) ${MODEL_NAMES[$idx]} - ${MODEL_DESCRIPTION[$idx]}"
        else
            echo "  $((n+1))) ${MODEL_NAMES[$idx]}"
        fi
    done

    echo
    get_input "Model: "
    local CHOICE="$GET_INPUT_RESULT"

    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#INDEXES[@]} ))
    then
        echo "Invalid choice."
        return
    fi

    CHOSEN_MODEL_INDEX="${INDEXES[$((CHOICE-1))]}"
}


# ==========================================================
# STEP 3: choose config preset (FAST / MIDDLE / HIGH)
# Sets the global CHOSEN_MODE. Called directly - NOT via $(...).
# ==========================================================

choose_config_mode()
{
    local FAMILY="$1"
    local -a MODES=("DRAFT" "FAST" "MIDDLE" "HIGH" "MAX")

    echo
    echo "======================================"
    echo "  STEP 3: Choose config"
    echo "======================================"

    for m in "${!MODES[@]}"
    do
        local key="${FAMILY}:${MODES[$m]}"
        local flags="${CONFIG_FLAGS[$key]}"
        echo "  $((m+1))) ${MODES[$m]}   ($flags)"
    done

    echo
    get_input "Config: "
    local CHOICE="$GET_INPUT_RESULT"

    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#MODES[@]} ))
    then
        echo "Invalid choice, defaulting to FAST."
        CHOSEN_MODE="FAST"
        return
    fi

    CHOSEN_MODE="${MODES[$((CHOICE-1))]}"
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
    echo "Launching sd-server... cmdline: $SD_SERVER  $ARGS $PRESET_FLAGS"

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
# Runs the variety -> model -> config -> launch flow.
# Reads its answers from ANSWER_QUEUE if it's populated (preset),
# otherwise prompts interactively (manual). Returns non-zero if the
# flow was aborted (invalid choice) so the caller can pause briefly.
# ==========================================================

do_launch_flow()
{
    local FAMILY MODEL_INDEX MODE

    choose_family
    FAMILY="$CHOSEN_FAMILY"
    if [[ -z "$FAMILY" ]]; then
        ANSWER_QUEUE=()
        return 1
    fi

    choose_model "$FAMILY"
    MODEL_INDEX="$CHOSEN_MODEL_INDEX"
    if [[ "$MODEL_INDEX" == "-1" ]]; then
        ANSWER_QUEUE=()
        return 1
    fi

    choose_config_mode "$FAMILY"
    MODE="$CHOSEN_MODE"

    launch_model "$MODEL_INDEX" "$MODE"

    ANSWER_QUEUE=()
    return 0
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

    NUM_PRESETS=${#PRESET_NAMES[@]}

    for i in "${!PRESET_NAMES[@]}"
    do
        echo "$((i+1))) ${PRESET_NAMES[$i]}"
    done

    MANUAL_CHOICE=$((NUM_PRESETS + 1))
    EXIT_CHOICE=$((NUM_PRESETS + 2))

    echo "${MANUAL_CHOICE}) Manual"
    echo "${EXIT_CHOICE}) Exit"
    echo

    read -r -p "Choice: " TOP_CHOICE

    if [[ "$TOP_CHOICE" =~ ^[0-9]+$ ]] && (( TOP_CHOICE >= 1 && TOP_CHOICE <= NUM_PRESETS ))
    then
        # ------------------------------------------------
        # Preset: pre-load the answers it types at the
        # variety/model/config prompts. Preset answer strings
        # are "top,variety,model,config" (matching the digits
        # you'd type by hand); the leading "top" digit is a
        # holdover from when "Launch a model" was choice 1 and
        # is discarded here since picking a preset already
        # implies "launch a model".
        # ------------------------------------------------
        PRESET_IDX=$((TOP_CHOICE - 1))
        IFS=',' read -r -a RAW_ANSWERS <<< "${PRESET_ANSWERS[$PRESET_IDX]}"

        if [[ ${#RAW_ANSWERS[@]} -ge 4 ]]; then
            ANSWER_QUEUE=("${RAW_ANSWERS[@]:1}")
        else
            ANSWER_QUEUE=("${RAW_ANSWERS[@]}")
        fi

        echo
        echo "Preset: ${PRESET_NAMES[$PRESET_IDX]}"

        do_launch_flow

        echo
        read -r -p "Press Enter to return to menu"

    elif [[ "$TOP_CHOICE" == "$MANUAL_CHOICE" ]]
    then
        ANSWER_QUEUE=()
        do_launch_flow

        echo
        read -r -p "Press Enter to return to menu"

    elif [[ "$TOP_CHOICE" == "$EXIT_CHOICE" ]]
    then
        exit 0

    else
        echo "Invalid choice"
        sleep 1
    fi

done
