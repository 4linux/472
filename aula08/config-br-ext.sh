#!/bin/bash
ip link set br-ext up
ip addr replace 203.0.113.254/24 dev br-ext
