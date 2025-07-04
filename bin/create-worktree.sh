#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script usage
usage() {
    echo "Usage: $0 <branch-name> [base-branch]"
    echo ""
    echo "Creates a new git worktree with proper Rails credentials setup"
    echo ""
    echo "Arguments:"
    echo "  branch-name    Name of the new branch to create"
    echo "  base-branch    Base branch to create from (default: main)"
    echo ""
    echo "Example:"
    echo "  $0 add-items-index"
    echo "  $0 fix-n-plus-one develop"
    exit 1
}

# Check arguments
if [ $# -lt 1 ]; then
    usage
fi

BRANCH_NAME=$1
BASE_BRANCH=${2:-main}
MAIN_PATH=$(pwd)
WORKTREE_BASE=".git/worktrees"
WORKTREE_PATH="${WORKTREE_BASE}/${BRANCH_NAME}"

# Check if we're in the right directory
if [ ! -f "Gemfile" ] || [ ! -d ".git" ]; then
    echo -e "${RED}Error: This script must be run from the Rails project root${NC}"
    exit 1
fi

# Check if worktree already exists
if [ -d "$WORKTREE_PATH" ]; then
    echo -e "${RED}Error: Directory $WORKTREE_PATH already exists${NC}"
    exit 1
fi

echo -e "${GREEN}Creating worktree...${NC}"
echo "  Path: $WORKTREE_PATH"
echo "  Branch: $BRANCH_NAME"
echo "  Base: $BASE_BRANCH"

# Create base directory if it doesn't exist
mkdir -p "$WORKTREE_BASE"

# Create worktree
git worktree add "$WORKTREE_PATH" "$BASE_BRANCH" -b "$BRANCH_NAME"

echo -e "${GREEN}Setting up credentials...${NC}"

# Create necessary directories
mkdir -p "$WORKTREE_PATH/config/credentials"

# Link credential files
LINKED_FILES=(
    "config/credentials/development.key"
    "config/credentials/production.key"
)

for file in "${LINKED_FILES[@]}"; do
    if [ -f "$MAIN_PATH/$file" ]; then
        ln -s "$MAIN_PATH/$file" "$WORKTREE_PATH/$file"
        echo "  ✓ Linked $file"
    else
        echo -e "  ${YELLOW}⚠ Skipped $file (not found)${NC}"
    fi
done

# Link .env files if they exist
for env_file in .env .env.local .env.development .env.development.local; do
    if [ -f "$MAIN_PATH/$env_file" ]; then
        ln -s "$MAIN_PATH/$env_file" "$WORKTREE_PATH/$env_file"
        echo "  ✓ Linked $env_file"
    fi
done

# Link other important untracked files
OTHER_FILES=(
    "config/master.key"
    "storage/.keep"
)

for file in "${OTHER_FILES[@]}"; do
    if [ -f "$MAIN_PATH/$file" ]; then
        # Create directory if needed
        dir=$(dirname "$WORKTREE_PATH/$file")
        mkdir -p "$dir"
        # Check if the file already exists before linking
        if [ ! -e "$WORKTREE_PATH/$file" ]; then
            ln -s "$MAIN_PATH/$file" "$WORKTREE_PATH/$file"
            echo "  ✓ Linked $file"
        else
            echo "  ✓ $file already exists"
        fi
    fi
done

echo -e "${GREEN}Worktree setup completed!${NC}"
echo ""
echo "Next steps:"
echo "  cd $MAIN_PATH/$WORKTREE_PATH"
echo "  docker compose run --rm web bundle install"
echo "  docker compose run --rm web rails db:migrate"
echo ""
echo "To remove this worktree later:"
echo "  git worktree remove $WORKTREE_PATH"
echo ""
echo "To list all worktrees:"
echo "  git worktree list"
