#!/usr/bin/env bash
# One durable, supervisor-facing record for a merge that actually landed.
#
# A merge used to be the one lifecycle event that left no trace outside the
# merging agent's own memory: bin/fm-pr-merge.sh ended at the forge call, and a
# home merging under standing authority never waits for the merge poll that
# would otherwise confirm it. This library is the single owner of that record,
# so a merge this home performed itself and a merge someone else performed on
# the forge both arrive through one channel in one shape.
#
# The destination is the home's ROLE, never the caller's choice:
#   - a secondmate home reports upward to its parent, on the same reply channel
#     bin/fm-inactive-reconcile.sh's report_to_parent already uses, in the same
#     "<state> [key=<slug>]: <note>" shape the charter contract defines;
#   - a main home reports to the captain, through the durable wake queue.
# No new state file and no new transport: the parent channel and the wake queue
# are the two records the captain already reads.
#
# Normal operation deduplicates each task and canonical PR identity through the
# merge-notification marker owned by bin/fm-pr-lib.sh. The outcome is published
# before that marker is committed, so a failed commit stays eligible for
# at-least-once retry and may rarely duplicate rather than leave a merge silent.
#
# Sourced by bin/fm-pr-merge.sh, bin/fm-watch.sh, and tests. No side effects on
# source beyond its sourced libraries.

_FM_MERGE_OUTCOME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-secondmate-parent-lib.sh"

# The secondmate identity of the home reporting, or non-zero when this home is
# a main home (1) or carries an unusable identity marker (2). Mirrors
# bin/fm-inactive-reconcile.sh's home_secondmate_id, which owns the same
# marker's contract.
fm_merge_outcome_home_id() {  # <home>
  local home=$1 marker id
  marker="$home/.fm-secondmate-home"
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 1
  fi
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
  [ "$(wc -c < "$marker")" -eq "$(LC_ALL=C tr -d '\0' < "$marker" | wc -c)" ] || return 2
  id=$(cat "$marker" 2>/dev/null) || return 2
  fm_pr_task_id_valid "$id" || return 2
  printf '%s\n' "$id"
}

# Append <line> to <path> unless that exact line is already there, so a repeat
# report of the same merge cannot duplicate it.
fm_merge_outcome_append_once() {  # <path> <line>
  local path=$1 line=$2
  [ ! -L "$path" ] || return 1
  mkdir -p "$(dirname "$path")" || return 1
  if grep -Fqx -- "$line" "$path" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$line" >> "$path"
}

# shellcheck disable=SC2034 # Public result consumed by sourcing callers.
FM_MERGE_OUTCOME_ALREADY_RECORDED=false

# fm_merge_outcome_report <home> <state> <task-id> <pr-url> <origin>
#
# <origin> says who observed the merge, because that decides what is still
# missing:
#   self - this home performed the merge, so nothing else has recorded it.
#   poll - this home's merge poll detected a merge this home did not perform,
#          so the same canonical outcome also wakes this home after any upward
#          hop needed by a secondmate home.
#
# Returns 0 when the outcome is recorded (or already was), 2 on an invalid
# request, 3 when this home's own role or parent binding cannot be read well
# enough to say where the outcome belongs, and 1 on any other failure to
# record. A caller that has already merged must report a non-zero return rather
# than treat it as success: the merge landed and the record did not.
fm_merge_outcome_report() {  # <home> <state> <task-id> <pr-url> <origin>
  local home=$1 state=$2 id=$3 url=$4 origin=$5
  local self='' self_rc=0 destination='' line lock status=0
  local provider host path number
  # shellcheck disable=SC2034 # Sourced wake helpers consume these scoped globals.
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  FM_MERGE_OUTCOME_ALREADY_RECORDED=false
  case "$origin" in self|poll) ;; *) return 2 ;; esac
  fm_pr_task_id_valid "$id" || return 2
  fm_pr_url_parse "$url" || return 2
  provider=$FM_PR_PROVIDER
  host=$FM_PR_HOST
  path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  [ -d "$state" ] && [ ! -L "$state" ] || return 1

  if self=$(fm_merge_outcome_home_id "$home"); then
    fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" || return 3
    case "$FM_SECONDMATE_PARENT_ROUTE" in
      local)
        [ -n "$FM_SECONDMATE_PARENT_HOME" ] || return 3
        destination="$FM_SECONDMATE_PARENT_HOME/state/$self.status"
        ;;
      remote) destination="$state/parent-replies.status" ;;
      *) return 3 ;;
    esac
    line="done [key=merged-$id]: merged $id $FM_PR_URL"
  else
    self_rc=$?
    [ "$self_rc" -eq 1 ] || return 3
  fi

  STATE=$state
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_MERGE_OUTCOME_LIB_DIR/fm-wake-lib.sh"
  lock="$state/$id.pr-poll-merge-notified.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if fm_pr_poll_merge_already_notified "$state" "$id" \
    "$provider" "$host" "$path" "$number"; then
    # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
    FM_MERGE_OUTCOME_ALREADY_RECORDED=true
    fm_lock_release "$lock"
    return 0
  fi

  if [ -n "$destination" ]; then
    fm_merge_outcome_append_once "$destination" "$line" || status=1
  fi
  if [ "$status" -eq 0 ] && { [ "$origin" = poll ] || [ -z "$destination" ]; }; then
    fm_wake_append check "merged-$id-$FM_PR_URL" \
      "check: merge landed: $id $FM_PR_URL" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    fm_pr_poll_merge_mark_notified "$state" "$id" \
      "$provider" "$host" "$path" "$number" || status=1
  fi
  fm_lock_release "$lock"
  return "$status"
}
