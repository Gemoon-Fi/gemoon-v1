#!/bin/bash


source ${PWD}/secutiry/security/bin/activate


slither ${PWD}/src/contracts --exclude-dependencies --exclude test --exclude third-party --exclude node_modules --exclude scripts --exclude migrations --exclude interfaces --exclude utils