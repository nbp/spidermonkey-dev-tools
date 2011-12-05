#!/bin/sh

hg=/home/nicolas/mozilla/hg/ionmonkey
git=/home/nicolas/mozilla/ionmonkey

. /home/nicolas/.env

SSH_ENV="$HOME/.ssh/.env"
. "${SSH_ENV}" > /dev/null

export SYNC_REPOS=/home/nicolas/mozilla/sync-repos
export TS_SOCKET=/tmp/ionmonkey-sync.ts

pull () {
    repo=$1
    cd $hg
    # If this command fails, then all following will fail too, which avoid
    # pulling and updating the bookmarks.
    ts > /dev/null    -L hg-pull \
        $SYNC_REPOS/git-hg-pull.sh $repo

    cd $git
    ts  > /dev/null -d -L git-fetch \
        git fetch
}

push () {
    cd $hg
    ts > /dev/null -d -L "hg-push" \
        $SYNC_REPOS/git-hg-push.sh "$@"
}

cmd=$1
shift
case "$cmd" in
    (pull) $cmd $1;;
    (push) $cmd "$@";;
    (*) exit 1;;
esac
