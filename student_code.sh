#!/bin/sh
umask 007
export PYTHONPATH=/plugin/student_dir:.:src
exec "$@"
