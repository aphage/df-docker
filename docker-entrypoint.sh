#!/bin/bash
set -eo pipefail
shopt -s nullglob

DF_DATA_DIR=/df-data
DF_TMP_DIR=/tmp
APP_DIR=/app

# logging functions
log() {
	local type="$1"; shift
	# accept argument string or stdin
	local text="$*"; if [ "$#" -eq 0 ]; then text="$(cat)"; fi
	local dt; dt="$(date --rfc-3339=seconds)"
	printf '%s [%s] [Entrypoint]: %s\n' "$dt" "$type" "$text"
}
log_note() {
	log Note "$@"
}
log_warn() {
	log Warn "$@" >&2
}
log_error() {
	log ERROR "$@" >&2
	exit 1
}

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		log_error "Both $var and $fileVar are set (but are exclusive)"
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

# check to see if this file is being run or sourced from another script
_is_sourced() {
	# https://unix.stackexchange.com/a/215279
	[ "${#FUNCNAME[@]}" -ge 2 ] \
		&& [ "${FUNCNAME[0]}" = '_is_sourced' ] \
		&& [ "${FUNCNAME[1]}" = 'source' ]
}


# Loads various settings that are used elsewhere in the script
# This should be called after mysql_check_config, but before any other functions
docker_setup_env() {
	# Initialize values that might be stored in a file
	file_env 'MYSQL_IP'
	file_env 'MYSQL_PORT' '3306'
	file_env 'MYSQL_USER'
	file_env 'MYSQL_PASSWORD'
	file_env 'MY_IP'

	declare -g MYSQL_SECURITY_PASSWORD
	MYSQL_SECURITY_PASSWORD="$(df-crypto enc ${MYSQL_PASSWORD})"
}

# Verify that the minimally required password settings are set for df-server.
docker_verify_minimum_env() {
    if [ -z "$MYSQL_IP" -o -z "$MYSQL_PORT" ]; then
        log_error <<-'EOF'
			df-server is need to connect to MySQL and MYSQL_IP or MYSQL_PORT are not set
                You need to specify one of the following as an environment variable:
                - MYSQL_IP
                - MYSQL_PORT
		EOF
    fi

    if [ -z "$MYSQL_USER" -o -z "$MYSQL_PASSWORD" ]; then
        log_error <<-'EOF'
			df-server is need to connect to MySQL and MYSQL_USER or MYSQL_PASSWORD are not set
                You need to specify one of the following as an environment variable:
                - MYSQL_USER
                - MYSQL_PASSWORD
		EOF
    fi

	# check password length <= 20
	if [ ${#MYSQL_PASSWORD} -gt 20 ]; then
		log_error <<-'EOF'
			MYSQL_PASSWORD is too long
		EOF
	fi

    if [ -z "$MY_IP" ]; then
        log_error <<-'EOF'
			df-server is need to know MY_IP and MY_IP is not set
                You need to specify one of the following as an environment variable:
                - MY_IP
		EOF
    fi
}

docker_verify_minimum_df_data() {
	if [ ! -f ${DF_DATA_DIR}/publickey.pem ]; then
		log_error <<-'EOF'
			You need to create a publickey.pem file.
            Example:
                openssl genrsa -out privatekey.pem 2048
                openssl rsa -in privatekey.pem -outform PEM -pubout -out publickey.pem
		EOF
	fi

	if [ ! -f ${DF_DATA_DIR}/Script.pvf ]; then
		log_error "not found ${DF_DATA_DIR}/Script.pvf"
	fi
}

docker_wait() {
	if [ -z $1 ]; then
		return
	fi

	while kill -0 $1 2> /dev/null; do
		sleep 1
	done
}

escape() {
	echo "$1" | sed -e 's/[]\/$*.^[]/\\&/g'
}

docker_env_replace() {
	sed -i \
		-e "s/{MYSQL_IP}/$(escape ${MYSQL_IP})/g" \
		-e "s/{MYSQL_PORT}/$(escape ${MYSQL_PORT})/g" \
		-e "s/{MYSQL_USER}/$(escape ${MYSQL_USER})/g" \
		-e "s/{MYSQL_PASSWORD}/$(escape ${MYSQL_PASSWORD})/g" \
		-e "s/{MYSQL_SECURITY_PASSWORD}/$(escape ${MYSQL_SECURITY_PASSWORD})/g" \
		-e "s/{MY_IP}/$(escape ${MY_IP})/g" \
	"$@"
}

run_stun() {
	cd ${APP_DIR}/stun

	rm -rf ${DF_TMP_DIR}/stun-log
	rm -rf ${DF_TMP_DIR}/stun-pid
	mkdir -p ${DF_TMP_DIR}/stun-log
	mkdir -p ${DF_TMP_DIR}/stun-pid

	log_note "start stun"
	./df_stun_r start
}

stop_stun() {
	cd ${APP_DIR}/stun

	log_note "stop stun"
	kill $(cat pid/udp_server.pid)
}

run_monitor() {
	cd ${APP_DIR}/monitor

	rm -rf ${DF_TMP_DIR}/monitor-log
	rm -rf ${DF_TMP_DIR}/monitor-pid
	mkdir -p ${DF_TMP_DIR}/monitor-log
	mkdir -p ${DF_TMP_DIR}/monitor-pid

	log_note "start monitor"
	./df_monitor_r mnt_siroco start
}

stop_monitor() {
	cd ${APP_DIR}/monitor

	log_note "stop monitor"
	kill $(cat pid/mnt_siroco.pid)
}

run_manager() {
	cd ${APP_DIR}/manager

	rm -rf ${DF_TMP_DIR}/manager-log
	rm -rf ${DF_TMP_DIR}/manager-pid
	mkdir -p ${DF_TMP_DIR}/manager-log
	mkdir -p ${DF_TMP_DIR}/manager-pid

	log_note "start manager"
	./df_manager_r manager start
}

stop_manager() {
	cd ${APP_DIR}/manager

	log_note "stop manager"
	kill $(cat pid/manager.pid)
}

run_relay() {
	cd ${APP_DIR}/relay

	rm -rf ${DF_TMP_DIR}/relay-log
	rm -rf ${DF_TMP_DIR}/relay-pid
	mkdir -p ${DF_TMP_DIR}/relay-log
	mkdir -p ${DF_TMP_DIR}/relay-pid

	log_note "start relay"
	./df_relay_r relay_200 start
}

stop_relay() {
	cd ${APP_DIR}/relay

	log_note "stop relay"
	kill $(cat pid/relay_200.pid)
}

run_bridge() {
	cd ${APP_DIR}/bridge

	log_note <<-'EOF'
        This service can't change the MYSQL port.
        The MYSQL port must be 3306.
	EOF

	rm -rf ${DF_TMP_DIR}/bridge-log
	rm -rf ${DF_TMP_DIR}/bridge-pid
	rm -rf ${DF_TMP_DIR}/bridge-cfg
	mkdir -p ${DF_TMP_DIR}/bridge-log
	mkdir -p ${DF_TMP_DIR}/bridge-pid
	cp -rf _cfg ${DF_TMP_DIR}/bridge-cfg
	docker_env_replace cfg/bridge.cfg

	log_note "start bridge"
	./df_bridge_r bridge start
}

stop_bridge() {
	cd ${APP_DIR}/bridge

	log_note "stop bridge"
	kill $(cat pid/bridge.pid)
}

run_channel() {
	cd ${APP_DIR}/channel

	rm -rf ${DF_TMP_DIR}/channel-log
	rm -rf ${DF_TMP_DIR}/channel-pid
	rm -rf ${DF_TMP_DIR}/channel-cfg
	mkdir -p ${DF_TMP_DIR}/channel-log
	mkdir -p ${DF_TMP_DIR}/channel-pid
	cp -rf _cfg ${DF_TMP_DIR}/channel-cfg
	docker_env_replace cfg/channel.cfg

	log_note "start channel"
	./df_channel_r channel start
}

stop_channel() {
	cd ${APP_DIR}/channel

	log_note "stop channel"
	kill $(cat pid/channel.pid)
}

run_dbmw_guild() {
	cd ${APP_DIR}/dbmw_guild

	rm -rf ${DF_TMP_DIR}/dbmw_guild-log
	rm -rf ${DF_TMP_DIR}/dbmw_guild-pid
	rm -rf ${DF_TMP_DIR}/dbmw_guild-cfg
	mkdir -p ${DF_TMP_DIR}/dbmw_guild-log
	mkdir -p ${DF_TMP_DIR}/dbmw_guild-pid
	cp -rf _cfg ${DF_TMP_DIR}/dbmw_guild-cfg
	docker_env_replace cfg/dbmw_gld_siroco.cfg

	log_note "start dbmw_guild"
	./df_dbmw_r dbmw_gld_siroco start
}

stop_dbmw_guild() {
	cd ${APP_DIR}/dbmw_guild

	log_note "stop dbmw_guild"
	kill $(cat pid/dbmw_gld_siroco.pid)
}

run_dbmw_mnt() {
	cd ${APP_DIR}/dbmw_mnt

	rm -rf ${DF_TMP_DIR}/dbmw_mnt-log
	rm -rf ${DF_TMP_DIR}/dbmw_mnt-pid
	rm -rf ${DF_TMP_DIR}/dbmw_mnt-cfg
	mkdir -p ${DF_TMP_DIR}/dbmw_mnt-log
	mkdir -p ${DF_TMP_DIR}/dbmw_mnt-pid
	cp -rf _cfg ${DF_TMP_DIR}/dbmw_mnt-cfg
	docker_env_replace cfg/dbmw_mnt_siroco.cfg

	log_note "start dbmw_mnt"
	./df_dbmw_r dbmw_mnt_siroco start
}

stop_dbmw_mnt() {
	cd ${APP_DIR}/dbmw_mnt

	log_note "stop dbmw_mnt"
	kill $(cat pid/dbmw_mnt_siroco.pid)
}

run_dbmw_stat() {
	cd ${APP_DIR}/dbmw_stat

	rm -rf ${DF_TMP_DIR}/dbmw_stat-log
	rm -rf ${DF_TMP_DIR}/dbmw_stat-pid
	rm -rf ${DF_TMP_DIR}/dbmw_stat-cfg
	mkdir -p ${DF_TMP_DIR}/dbmw_stat-log
	mkdir -p ${DF_TMP_DIR}/dbmw_stat-pid
	cp -rf _cfg ${DF_TMP_DIR}/dbmw_stat-cfg
	docker_env_replace cfg/dbmw_stat_siroco.cfg

	log_note "start dbmw_stat"
	./df_dbmw_r dbmw_stat_siroco start
}

stop_dbmw_stat() {
	cd ${APP_DIR}/dbmw_stat

	log_note "stop dbmw_stat"
	kill $(cat pid/dbmw_stat_siroco.pid)
}

run_auction() {
	cd ${APP_DIR}/auction

	log_note <<-'EOF'
        This service have to connect to MySQL.
	EOF

	rm -rf ${DF_TMP_DIR}/auction-log
	rm -rf ${DF_TMP_DIR}/auction-pid
	rm -rf ${DF_TMP_DIR}/auction-cfg
	mkdir -p ${DF_TMP_DIR}/auction-log
	mkdir -p ${DF_TMP_DIR}/auction-pid
	cp -rf _cfg ${DF_TMP_DIR}/auction-cfg
	docker_env_replace cfg/auction_siroco.cfg

	log_note "start auction"
	./df_auction_r ./cfg/auction_siroco.cfg start df_auction_r
}

stop_auction() {
	cd ${APP_DIR}/auction

	log_note "stop auction"
	kill $(cat pid/auction_siroco.pid)
}

run_point() {
	cd ${APP_DIR}/point

	log_note <<-'EOF'
        This service have to connect to MySQL.
	EOF

	rm -rf ${DF_TMP_DIR}/point-log
	rm -rf ${DF_TMP_DIR}/point-pid
	rm -rf ${DF_TMP_DIR}/point-cfg
	mkdir -p ${DF_TMP_DIR}/point-log
	mkdir -p ${DF_TMP_DIR}/point-pid
	cp -rf _cfg ${DF_TMP_DIR}/point-cfg
	docker_env_replace cfg/point_siroco.cfg
	
	log_note "start point"
	./df_point_r ./cfg/point_siroco.cfg start df_point_r
}

stop_point() {
	cd ${APP_DIR}/point

	log_note "stop point"
	kill $(cat pid/point_siroco.pid)
}

run_guild() {
	cd ${APP_DIR}/guild

	rm -rf ${DF_TMP_DIR}/guild-log
	rm -rf ${DF_TMP_DIR}/guild-pid
	mkdir -p ${DF_TMP_DIR}/guild-log
	mkdir -p ${DF_TMP_DIR}/guild-pid

	log_note "start guild"
	./df_guild_r gld_siroco start
}

stop_guild() {
	cd ${APP_DIR}/guild

	log_note "stop guild"
	kill $(cat pid/gld_siroco.pid)
}

run_statics() {
	cd ${APP_DIR}/statics

	rm -rf ${DF_TMP_DIR}/statics-log
	rm -rf ${DF_TMP_DIR}/statics-pid
	mkdir -p ${DF_TMP_DIR}/statics-log
	mkdir -p ${DF_TMP_DIR}/statics-pid

	log_note "start statics"
	./df_statics_r stat_siroco start
}

stop_statics() {
	cd ${APP_DIR}/statics

	log_note "stop statics"
	kill $(cat pid/stat_siroco.pid)
}

run_coserver() {
	cd ${APP_DIR}/coserver

	rm -rf ${DF_TMP_DIR}/coserver-log
	rm -rf ${DF_TMP_DIR}/coserver-pid
	mkdir -p ${DF_TMP_DIR}/coserver-log
	mkdir -p ${DF_TMP_DIR}/coserver-pid

	log_note "start coserver"
	nice -n 19 ./df_coserver_r coserver start
}

stop_coserver() {
	cd ${APP_DIR}/coserver

	log_note "stop coserver"
	kill $(cat pid/coserver.pid)
}

run_community() {
	cd ${APP_DIR}/community

	rm -rf ${DF_TMP_DIR}/community-log
	rm -rf ${DF_TMP_DIR}/community-pid
	mkdir -p ${DF_TMP_DIR}/community-log
	mkdir -p ${DF_TMP_DIR}/community-pid

	log_note "start community"
	./df_community_r community start
}

stop_community() {
	cd ${APP_DIR}/community

	log_note "stop community"
	kill $(cat pid/community.pid)
}

# secsvr/gunnersvr
run_secsvr_gunnersvr() {
	rm -rf ${DF_TMP_DIR}/secsvr-gunnersvr
	mkdir -p ${DF_TMP_DIR}/secsvr-gunnersvr
	cd ${DF_TMP_DIR}/secsvr-gunnersvr
	ln -sf ${APP_DIR}/secsvr/gunnersvr/cfg cfg

	log_note "start secsvr/gunnersvr"

	PRELOAD="/usr/local/lib/libdeslash_shm.so ${LD_PRELOAD}"

	LD_PRELOAD=${PRELOAD} ${APP_DIR}/secsvr/gunnersvr/gunnersvr -t30 -i1 &
}

stop_secsvr_gunnersvr() {
	cd ${DF_TMP_DIR}/secsvr-gunnersvr

	log_note "stop secsvr/gunnersvr"
	kill $(cat gunnersvr.pid)
}

# secsvr/zergsvr
run_secsvr_zergsvr() {
	rm -rf ${DF_TMP_DIR}/secsvr-zergsvr
	mkdir -p ${DF_TMP_DIR}/secsvr-zergsvr
	cd ${DF_TMP_DIR}/secsvr-zergsvr
	ln -sf ${APP_DIR}/secsvr/zergsvr/cfg cfg

	log_note "start secsvr/zergsvr"

	PRELOAD="/usr/local/lib/libdeslash_shm.so ${LD_PRELOAD}"

	LD_PRELOAD=${PRELOAD} ${APP_DIR}/secsvr/zergsvr/zergsvr -t30 -i1 &
}

# secsvr/secagent
run_secsvr_secagent() {
	rm -rf ${DF_TMP_DIR}/secsvr-secagent
	mkdir -p ${DF_TMP_DIR}/secsvr-secagent
	cd ${DF_TMP_DIR}/secsvr-secagent
	ln -sf ${APP_DIR}/secsvr/zergsvr/cfg cfg

	log_note "start secsvr/secagent"

	PRELOAD="/usr/local/lib/libdeslash_shm.so ${LD_PRELOAD}"

	LD_PRELOAD=${PRELOAD} ${APP_DIR}/secsvr/zergsvr/secagent &
}

stop_secsvr_secagent() {
	cd ${DF_TMP_DIR}/secsvr-secagent

	log_note "stop secsvr/secagent"
	kill $(cat secagent.pid)
}

run_game() {
	cd ${APP_DIR}/game

	rm -rf ${DF_TMP_DIR}/game-log
	rm -rf ${DF_TMP_DIR}/game-pid
	rm -rf ${DF_TMP_DIR}/game-history
	mkdir -p ${DF_TMP_DIR}/game-log
	mkdir -p ${DF_TMP_DIR}/game-pid
	mkdir -p ${DF_TMP_DIR}/game-history

	if [ $# -eq 0 ]; then
		log_error "You need to specify at least one channel."
	fi

	if [ ! -d ${DF_TMP_DIR}/game-cfg ]; then
		log_note "copy game-cfg"
		cp -rf _cfg ${DF_TMP_DIR}/game-cfg
		docker_env_replace $(find ${DF_TMP_DIR}/game-cfg -type f -name "*.cfg")
	fi

	for c in "$@"; do
		if [ ! -f ${DF_TMP_DIR}/game-cfg/$c.cfg ]; then
			log_error "not found ${DF_TMP_DIR}/game-cfg/$c.cfg"
		fi
	done
	
	LIBRARY_PATH=${APP_DIR}/game:/usr/local/lib:${LD_LIBRARY_PATH}
	PRELOAD="$(pwd)/libfix-antisvr.so /usr/local/lib/libdeslash_shm.so ${LD_PRELOAD}"

	for c in "$@"; do
		log_note "start game $c"
		LD_LIBRARY_PATH=${LIBRARY_PATH} \
		LD_PRELOAD=${PRELOAD} ./df_game_r $c start
	done
}

stop_game() {
	cd ${APP_DIR}/game

	LIBRARY_PATH=${APP_DIR}/game:/usr/local/lib:${LD_LIBRARY_PATH}

	for c in "$@"; do
		log_note "stop game $c"
		kill -9 $(cat pid/$c.pid)
	done
}

run() {
	if [ $# -eq 0 ]; then
		log_error "You need to specify at least one channel."
	fi

	run_stun
	run_monitor
	run_manager
	run_relay
	run_bridge
	run_channel
	run_dbmw_guild
	run_dbmw_mnt
	run_dbmw_stat
	run_auction
	run_point
	run_guild
	run_statics
	run_coserver
	run_community
	run_secsvr_gunnersvr
	run_secsvr_secagent
	run_secsvr_zergsvr

	run_game "$@"

	stop() {
		stop_secsvr_secagent
		stop_secsvr_gunnersvr
		stop_coserver
		stop_community
		stop_point
		stop_guild
		stop_statics
		stop_dbmw_mnt
		stop_dbmw_stat
		stop_dbmw_guild
		stop_bridge
		stop_relay
		stop_manager
		stop_monitor
		stop_stun

		stop_game "$@"
	}

	trap '' SIGINT
	trap "stop $@" SIGTERM

	sleep 10

	docker_wait $(cat ${DF_TMP_DIR}/game-pid/$1.pid)

	log_note "done"
}

help() {
	echo <<-'EOF'
		Example:
			run siroco11
			run siroco11 siroco12 ...
	EOF
}

_main() {
	if [ $1 = "help" ]; then
		help
		exit 0
	elif [ $1 = "run" ]; then
		docker_setup_env
		docker_verify_minimum_env
		docker_verify_minimum_df_data

		shift
		run "$@"
		exit 0
	fi

	exec "$@"
}


# If we are sourced from elsewhere, don't perform any further actions
if ! _is_sourced; then
	_main "$@"
fi