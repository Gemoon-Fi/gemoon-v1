#!/bin/bash

if [ -z $ENVIRONMENT ]; then
	echo ENVIRO
fi

make ENVIRONMENT=${ENVIRONMENT} prepare-abi
make ENVIRONMENT=${ENVIRONMENT} contracts-map