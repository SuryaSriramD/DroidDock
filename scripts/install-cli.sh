#!/bin/bash
set -euo pipefail

# Run this copy inside the installed app. An optional directory supports custom
# user PATH locations without editing shell profiles or requesting root access.
CLI_SOURCE=$(cd "$(dirname "$0")/../MacOS" && pwd)/droiddock
CLI_DIRECTORY=${1:-"$HOME/.local/bin"}
if [[ ! -x "$CLI_SOURCE" ]]; then
  printf 'Run the installer bundled in DroidDock.app/Contents/Resources.\n' >&2
  exit 1
fi
mkdir -p "$CLI_DIRECTORY"
CLI_DIRECTORY=$(cd "$CLI_DIRECTORY" && pwd)
CLI_DESTINATION="$CLI_DIRECTORY/droiddock"
if [[ -L "$CLI_DESTINATION" ]]; then
  if [[ "$(readlink "$CLI_DESTINATION")" != "$CLI_SOURCE" ]]; then
    printf 'A different link already exists at %s. Remove it explicitly before reinstalling.\n' "$CLI_DESTINATION" >&2
    exit 1
  fi
elif [[ -e "$CLI_DESTINATION" ]]; then
  printf 'An existing file at %s was left unchanged.\n' "$CLI_DESTINATION" >&2
  exit 1
else
  ln -s "$CLI_SOURCE" "$CLI_DESTINATION"
fi
printf 'Installed %s\n' "$CLI_DESTINATION"
case ":$PATH:" in
  *":$CLI_DIRECTORY:"*) printf 'Ready: droiddock --help\n' ;;
  *) printf 'Add this directory to your shell PATH, or run the full path above.\nFor this terminal session:\nexport PATH=%q:"$PATH"\n' "$CLI_DIRECTORY" ;;
esac
