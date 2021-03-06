#!/bin/bash

set -u
set -o  errexit

working_dir=`dirname $0`

cd $working_dir
cd ..

./script/run_carton.sh exec xgettext.pl -w -v -v -v -P perl=* -P tt2=* --output=lib/MediaWords/I18N/messages.pot --directory=root/public_ui/ --directory=lib/
sed -i -e 's/Content-Type: text\/plain; charset=CHARSET/Content-Type: text\/plain; charset=UTF8/' lib/MediaWords/I18N/messages.pot 
cp lib/MediaWords/I18N/messages.pot   lib/MediaWords/I18N/en.po 
echo "Starting autotranslate"
./script/run_carton.sh exec autotranslate-po.pl -f en -t ru -i lib/MediaWords/I18N/messages.pot -o lib/MediaWords/I18N/ru.po

