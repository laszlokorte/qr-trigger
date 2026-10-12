yarn build
rsync -a build/ laszlo7@laszlo7.uber.space:/var/www/virtual/laszlo7/qr.laszlokorte.de/
start "https://qr.laszlokorte.de/"
