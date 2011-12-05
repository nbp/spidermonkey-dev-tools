#!/bin/sh

repo=$1

# Check if there is any pending changes.
if hg incoming --bundle .hg/incoming.bundle $repo; then
    # Pull latest changes.
    hg pull $repo

    # If there are incoming changes, then the tip will point to them.  Thus
    # reset the corresponding branch to the tip.
    branch=$repo/master
    hg bookmark -f $branch -r tip

    # Update the git clone.
    hg gexport
fi
