#!/usr/bin/env bash
clear
python3 -m pygments -f terminal256 -O style=monokai demo/sample.py
exec sleep 3600
