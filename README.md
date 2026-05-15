Служба под CentOS 7 забирает данные с навигационного сервера AKE

и передаёт полученное количество мест согласно выбранным зонам и этажам на табло Трансдеталь.

Настраиваются IP обоих сервисов

также существует вебморда для настройки по адресу:

http://IP:8080/

Запуск:

curl -fsSL https://raw.githubusercontent.com/88Dand/AKE-to-Transdetal-proxy/main/parking-proxy-install.sh | tr -d '\r' | bash
