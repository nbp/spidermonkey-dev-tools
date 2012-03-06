#!/bin/sh -e

# These paths are relative to $hgrepo
lockfile=./.hg/sync.lock
gitClone=./.hg/git
repoPath=./.hg/repos
bridgePath=./.hg/bridge
pullFlag=./.hg/pull.run

# This script takes the same arguments as the git update hook and is
# expected to be run inside one of the git-clone git-dir.

usage() {
    echo 1>&2 'push.sh <ref> <oldrev> <newrev>

Import git modifications from a mapped repository and try to push its master
branch to the corresponding mercurial repository.'
    exit 1
}

test $# -ne 3 && usage;
ref=$1
oldrev=$2
newrev=$3


GIT_DIR=$(pwd)
export GIT_DIR

hgrepo=$(git config hooks.bridge.location)
edgeName=$(git config hooks.bridge.edgeName)
pushOnly=$(git config hooks.bridge.pushOnly)

# If oldrev is not the merge base, this means a fast-forward was need to
# push the newrev of this reference.
force=
if test $oldrev != "$(git merge-base $oldrev $newrev)"; then
    echo "Will Force update!"
    # Mercurial flag forcing hg push.
    force=-f
fi


cd $hgrepo;
hgrepo=$(pwd)
test -d $bridgePath



# The double lock gives the priority to the pusher and avoid locking
# concurrent git repositories.
# fun: Ensure your road to the bridge is empty.
echo "Get git repository lock for pushing to the bridge."
( flock -x 11;

    # Setup the hidden branch which would be pushed to git-bridge.
    git update-ref -m "Pushing to mercurial" \
        refs/push/master $newrev

    # Push from the git-repo to the git-bridge, the config rules are
    # renaming the branch to refs/heads/$edgeName/push (or $edgeName/push bookmark)
    git push origin

# fun: Ensure nobody is crossing the bridge.
echo "Get mercurial repository lock for pushing from the bridge."
( flock -x 10;

    # Import changes into mercurial.
    if ! hg gimport; then
        error=$?
        echo "The bridge collasped, try again once it is repaired. (Exit code $error)"
    fi

    if hg push $force -r $edgeName/push $edgeName; then
        if test $pushOnly = true ; then
            # Update the bookmark of the main branch of the repository in which
            # we pushed because the tip will not be updated by the next pull.
            hg bookmark -f $edgeName/master -r $edgeName/push

            # Export the bookmark update to the git-bridge.
            hg gexport
        fi
    else
        error=$?
        # fun: Your visa has been refused at the border, update your work status.
        echo "Changes refused by mercurial remote. (Exit code $error)"
    fi

    hg bookmark -d $edgeName/push

) 10> $lockfile

    # Push from the git-repo to the git-bridge
    test $pushOnly = true || \
        git fetch origin

) 11> $lockfile.$edgeName

exit $error
