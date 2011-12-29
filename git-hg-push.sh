#!/bin/sh

# This script is made to be used as a post-update hook of the git clone produced
# by hg-git.

error=0

# Remove current bookmarks.
for ref in "$@"; do
    bookmark=${ref#refs/heads/}
    repo=${bookmark%%/*}
    hg bookmark -d $bookmark || true
done

# Import changes into mercurial.
echo "Import changes into mercurial."
hg gimport

for ref in "$@"; do
    bookmark=${ref#refs/heads/}
    repo=${bookmark%%/*}

    force=
    test "$repo" = try && force=-f

    # Push to the repository named as first member of the branch.
    if hg push $force -r $bookmark $repo; then
        test "$repo" = try && continue

        # Update the bookmark of the main branch of the repository where we pushed.
        branch=$repo/master
        hg bookmark -f $branch -r $bookmark

        # Export the bookmarks update to git.
        hg gexport
    else
        error=$?
        echo "Error during push: exit $error"
    fi
done

exit $error
