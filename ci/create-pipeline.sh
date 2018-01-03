#!/bin/bash

set -e
set -x

TARGET=${TARGET:-local}

fly validate-pipeline --config pipeline.yml

fly --target ${TARGET} set-pipeline --config pipeline.yml --pipeline create-boshrelease-dta-frontend -n -l credentials.yml

fly -t ${TARGET} unpause-pipeline -p create-boshrelease-dta-frontend
