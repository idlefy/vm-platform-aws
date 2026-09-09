#!/bin/sh
input=$(cat)

# Session name: prefer human-readable name, fall back to first 8 chars of session_id
session_name=$(echo "$input" | jq -r '.session_name // empty')
if [ -z "$session_name" ]; then
  session_id=$(echo "$input" | jq -r '.session_id // empty')
  session_name=$(echo "$session_id" | cut -c1-8)
fi

# Model display name
model=$(echo "$input" | jq -r '.model.display_name // empty')

# Reasoning effort level (only present on models that support it)
effort=$(echo "$input" | jq -r '.effort.level // empty')
if [ -n "$effort" ]; then
  effort_str="effort: ${effort}"
else
  effort_str=""
fi

# Context usage (used % only)
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
if [ -n "$used" ]; then
  used_int=$(printf '%.0f' "$used")
  ctx_str="ctx: ${used_int}% used"
else
  ctx_str=""
fi

# Git branch of cwd
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
if [ -n "$cwd" ]; then
  git_branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
else
  git_branch=""
fi

# Rate limits: 5-hour window only
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
if [ -n "$five_pct" ]; then
  five_int=$(printf '%.0f' "$five_pct")
  rate_str="5h: ${five_int}%"
else
  rate_str=""
fi

# Session cost in USD
cost_raw=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
cost_str=$(printf '$%.2f' "$cost_raw")

# Assemble parts separated by " | "
out=""
for part in "$session_name" "$model" "$effort_str" "$ctx_str" "$git_branch" "$rate_str" "$cost_str"; do
  if [ -n "$part" ]; then
    if [ -z "$out" ]; then
      out="$part"
    else
      out="$out | $part"
    fi
  fi
done

printf '%s' "$out"
