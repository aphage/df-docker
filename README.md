# df-dockerfile

## Pull

```sh
sudo docker pull registry.hub.docker.com/aphage/df-server:0.0.1
```

## Generate RSA 2048 key

```sh
openssl genrsa -out privatekey.pem 2048
openssl rsa -in privatekey.pem -outform PEM -pubout -out publickey.pem
```

## Prepare df-data

```sh
mkdir -p df-data
cp publickey.pem df-data
cp Script.pvf df-data
```

## Run

```sh
sudo docker run --cap-add=sys_nice --rm -it \
-e MYSQL_IP=192.168.0.2 \
-e MYSQL_PORT=3306 \
-e MYSQL_USER=root \
-e MYSQL_PASSWORD=root \
-e MY_IP=192.168.0.2 \
--mount type=bind,src="$(pwd)"/df-data,target=/df-data \
--network host --shm-size 256m --memory 1g \
--memory-swap -1 \
df-server:0.0.1 run siroco12
```