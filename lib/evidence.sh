#!/usr/bin/env bash
# ==============================================================================
# evidence.sh
# ==============================================================================
#
# Shared evidence and log management helpers for NSSA320 Lab 7.
#
# Purpose:
#  - Create evidence and archive directories
#  - Archive existing evidence before generating new output
#  - Prevent accidental overwriting of professor-facing evidence
#  - Keep evidence handling consistent across Lab 7 scripts
#
# Design:
#  - This file does not automatically run actions when sourced.
#  - Validation and setup scripts call these functions as needed.
#  - Output is handled through lib/common.sh.
#  - This library manages files and directories, not evidence content.
#
# RICE Framework:
#  - Reproducibility: Evidence follows a predictable directory structure.
#  - Idempotency: Existing evidence is archived instead of overwritten.
#  - Composability: Multiple scripts can reuse the same helpers.
#  - Evolvability: New evidence types can use the same archive workflow.
#
# Dependencies:
#  - lib/common.sh must be sourced before this file is used.
#
# Author:
#  - Jared Husson
#
# ==============================================================================
# Version History
# ==============================================================================
#
# Version: 2.0
# Date: 2026-07-23
#
# Changes:
#  - Migrated the evidence helper library from Lab 4 to Lab 7.
#  - Updated the source guard and documentation.
#  - Added generic evidence-file archiving for multiple file extensions.
#  - Improved attempt-number detection to avoid duplicate archive names.
#
# Version: 1.0
# Date: 2026-06-10
#
# Changes:
#  - Added evidence directory preparation helper.
#  - Added reusable evidence log archive helper.
#  - Added attempt-number and timestamp-based archive naming.
#  - Added basic evidence file existence helper.
#
# ==============================================================================


# ==============================================================================
# Source Guard
# ==============================================================================

if [[ -n "${LAB7_EVIDENCE_SH_LOADED:-}" ]]; then
    return 0
fi

LAB7_EVIDENCE_SH_LOADED="true"


# ==============================================================================
# Evidence Directory Helpers
# ==============================================================================

prepare_evidence_directories() {
    local evidence_dir="${1:-}"
    local archive_dir="${2:-}"

    step "Preparing evidence directories"

    if [[ -z "$evidence_dir" || -z "$archive_dir" ]]; then
        die "Usage: prepare_evidence_directories <evidence_dir> <archive_dir>"
    fi

    mkdir -p "$evidence_dir" ||
        die "Failed to create evidence directory: ${evidence_dir}"

    mkdir -p "$archive_dir" ||
        die "Failed to create archive directory: ${archive_dir}"

    pass "Evidence directory ready: ${evidence_dir}"
    pass "Archive directory ready: ${archive_dir}"
}

evidence_file_exists() {
    local evidence_file="${1:-}"

    if [[ -z "$evidence_file" ]]; then
        die "Usage: evidence_file_exists <evidence_file>"
    fi

    [[ -f "$evidence_file" ]]
}


# ==============================================================================
# Evidence Archive Helpers
# ==============================================================================

get_next_attempt_number() {
    local archive_dir="${1:-}"
    local file_prefix="${2:-}"
    local highest_attempt=0
    local archive_file
    local archive_name
    local attempt_number

    if [[ -z "$archive_dir" || -z "$file_prefix" ]]; then
        die "Usage: get_next_attempt_number <archive_dir> <file_prefix>"
    fi

    if [[ ! -d "$archive_dir" ]]; then
        printf '%03d\n' 1
        return 0
    fi

    while IFS= read -r archive_file; do
        archive_name="$(basename "$archive_file")"

        if [[ "$archive_name" =~ -attempt-([0-9]+)- ]]; then
            attempt_number=$((10#${BASH_REMATCH[1]}))

            if (( attempt_number > highest_attempt )); then
                highest_attempt="$attempt_number"
            fi
        fi
    done < <(
        find "$archive_dir" \
            -maxdepth 1 \
            -type f \
            -name "${file_prefix}-attempt-*" \
            2>/dev/null
    )

    printf '%03d\n' "$((highest_attempt + 1))"
}

archive_existing_evidence() {
    local evidence_file="${1:-}"
    local archive_dir="${2:-}"
    local file_prefix="${3:-}"
    local timestamp
    local attempt_number
    local extension
    local archived_file

    step "Checking for existing evidence"

    if [[ -z "$evidence_file" || -z "$archive_dir" || -z "$file_prefix" ]]; then
        die "Usage: archive_existing_evidence <evidence_file> <archive_dir> <file_prefix>"
    fi

    if [[ ! -f "$evidence_file" ]]; then
        pass "No existing evidence found. A new file will be created."
        return 0
    fi

    mkdir -p "$archive_dir" ||
        die "Failed to create archive directory: ${archive_dir}"

    timestamp="$(date +%Y%m%d-%H%M%S)"
    attempt_number="$(get_next_attempt_number "$archive_dir" "$file_prefix")"

    if [[ "$(basename "$evidence_file")" == *.* ]]; then
        extension=".${evidence_file##*.}"
    else
        extension=""
    fi

    archived_file="${archive_dir}/${file_prefix}-attempt-${attempt_number}-${timestamp}${extension}"

    info "Existing evidence found: ${evidence_file}"
    info "Archiving previous evidence to: ${archived_file}"

    mv "$evidence_file" "$archived_file" ||
        die "Failed to archive existing evidence: ${evidence_file}"

    pass "Previous evidence archived successfully"
}

archive_existing_log() {
    archive_existing_evidence "$@"
}

show_evidence_location() {
    local evidence_file="${1:-}"
    local archive_dir="${2:-}"

    if [[ -z "$evidence_file" || -z "$archive_dir" ]]; then
        die "Usage: show_evidence_location <evidence_file> <archive_dir>"
    fi

    step "Evidence file locations"

    info "Current evidence file: ${evidence_file}"
    info "Archive directory: ${archive_dir}"

    if [[ -f "$evidence_file" ]]; then
        pass "Current evidence file exists: ${evidence_file}"
    else
        warn "Current evidence file does not exist yet: ${evidence_file}"
    fi
}
