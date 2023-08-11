#!/bin/bash
echo スクリプトのあるディレクトリへ移動
cd `dirname $0`

sudo docker compose up -d --force-recreate
