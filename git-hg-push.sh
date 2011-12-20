#!/bin/sh

# This script is made to be used as a post-update hook of the git clone produced
# by hg-git.

# Import changes into mercurial.
hg gimport

for ref in "$@"; do
    bookmark=${ref#refs/heads/}
    repo=${bookmark%%/*}

    force=
    test "$repo" = try && force=-f

    # we need to push the revision number instead of the bookmarks, otherwise it
    # is shared on the repository and everybody will get it.
    rev=$(hg bookmarks | sed -n '\, '$bookmark' , { s,.*:,,; p }')

    # Push to the repository named as first member of the branch.
    if hg push $force -B $bookmark $repo; then
        test "$repo" = try && continue

        # Update the bookmark of the main branch of the repository where we pushed.
        branch=$repo/master
        hg bookmark -f $branch -r $bookmark

        # Export the bookmarks update to git.
        hg gexport
    else
        error=$?
        echo "Error during push: exit $error"
        exit $error
    fi
done
