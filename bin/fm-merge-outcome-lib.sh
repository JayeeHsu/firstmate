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
# At most once per task and canonical PR identity. The upward line is appended
# only when an identical line is absent, and a self-performed merge records the
# canonical merge-notification marker owned by bin/fm-pr-lib.sh, so a later poll
# detection of that same merge is absorbed instead of reported a second time.
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

# The durable wake for a main home. bin/fm-wake-lib.sh owns the queue but
# assigns its own globals when sourced, so they are declared local here: that
# contains them to this call instead of leaking into every script that sources
# this library.
_fm_merge_outcome_wake() {  # <state> <key> <payload>
  local state=$1 key=$2 payload=$3
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  STATE=$state
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_MERGE_OUTCOME_LIB_DIR/fm-wake-lib.sh"
  fm_wake_append check "$key" "$payload"
}

# fm_merge_outcome_report <home> <state> <task-id> <pr-url> <origin>
#
# <origin> says who observed the merge, because that decides what is still
# missing:
#   self - this home performed the merge, so nothing else has recorded it.
#   poll - this home's merge poll detected a merge this home did not perform,
#          and the caller has already enqueued that poll's own durable row here.
#          Only the upward hop out of a secondmate home is still missing, which
#          is why the captain's own forge merge and a self-performed merge share
#          this one path instead of needing a second one.
#
# Returns 0 when the outcome is recorded (or already was), 2 on an invalid
# request, 3 when this home's own role or parent binding cannot be read well
# enough to say where the outcome belongs, and 1 on any other failure to
# record. A caller that has already merged must report a non-zero return rather
# than treat it as success: the merge landed and the record did not.
fm_merge_outcome_report() {  # <home> <state> <task-id> <pr-url> <origin>
  local home=$1 state=$2 id=$3 url=$4 origin=$5
  local self='' self_rc=0 destination line
  case "$origin" in self|poll) ;; *) return 2 ;; esac
  fm_pr_task_id_valid "$id" || return 2
  fm_pr_url_parse "$url" || return 2
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
    fm_merge_outcome_append_once "$destination" "$line" || return 1
  else
    self_rc=$?
    [ "$self_rc" -eq 1 ] || return 3
    if [ "$origin" = self ]; then
      _fm_merge_outcome_wake "$state" "merged-$id" \
        "check: merge landed: $id $FM_PR_URL" || return 1
    fi
  fi

  # Only a self-performed merge has to claim the canonical identity: the poll
  # path's caller owns that marker for the merge it detected. Failing to record
  # it can cost a duplicate report later, which is not a reason to call a merge
  # that IS reported unreported.
  if [ "$origin" = self ]; then
    fm_pr_poll_merge_mark_notified "$state" "$id" \
      "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" || true
  fi
  return 0
}
