Служба под CentOS 7 забирает данные с навигационного сервера AKE

и передаёт полученное количество мест согласно выбранным зонам и этажам на табло Трансдеталь.



 существует вебморда для настройки по адресу:

http://IP:8080/

В ней настраиваются IP обоих сервисов, зоны и этажи для суммирования и передачи мест в табло

Запуск:

curl -fsSL https://raw.githubusercontent.com/88Dand/AKE-to-Transdetal-proxy/main/parking-proxy-install.sh | tr -d '\r' | bash

Конфиг лежит в /etc/parking/

файлы для компиляции кладутся в /opt/parking/

логи в var log parking
