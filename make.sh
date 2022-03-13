#!/bin/sh
set -e

BASE=`dirname $0`

while getopts :v OPT; do
    case $OPT in
        v|+v)
            VERBOSE=t
            ;;
        *)
            echo "usage: `basename $0` [+-v} [--] ARGS..."
            exit 2
    esac
done
shift `expr $OPTIND - 1`
OPTIND=1

export SOURCE_DATE_EPOCH=0
if [[ -d ${BASE}/.git ]] ; then
  # Unix timestamp of the commit we are building
  export SOURCE_DATE_EPOCH=$(git -C $BASE/ show -s --format=%ct HEAD)
fi

exec sbcl --load "$BASE/jscl.lisp" --eval "(jscl:bootstrap $VERBOSE)" --eval '(quit)'
