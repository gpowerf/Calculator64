#!/bin/bash
# Build the GUI64 calculator app and package it into a D64 image
set -e
cd "$(dirname "$0")"

echo "== Assembling calculator..."
acme -f cbm -o calculator.gui Calculator.asm

echo "== Creating disk image..."
rm -f calculator.d64
c1541 -format "calculator,64" d64 calculator.d64
c1541 calculator.d64 -write calculator.gui calculator.gui

echo "== Disk contents:"
c1541 calculator.d64 -list

echo "== Done: calculator.d64"