netsh interface portproxy reset
netsh interface portproxy add v4tov4 listenport=3000 listenaddress=127.0.0.1 connectport=8080 connectaddress=ECT01144
netsh interface portproxy show all
pause
