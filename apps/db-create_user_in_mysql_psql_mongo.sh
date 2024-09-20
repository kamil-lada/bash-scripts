#!/bin/bash

# Check if the correct number of arguments are provided
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <db_engine> <address> <port>"
    echo "db_engine should be one of: mysql, postgresql, mongodb"
    exit 1
fi

# Assign arguments to variables
DB_ENGINE=$1
ADDRESS=$2
PORT=$3

case "$DB_ENGINE" in
    mysql)
        echo -n "Enter MariaDB root password: "
        read -s ROOT_PASSWORD
        echo
        echo -n "Enter new MariaDB database name: "
        read DB_NAME
        echo
        mysql -h "$ADDRESS" -P "$PORT" -u root -p"$ROOT_PASSWORD" -e "CREATE DATABASE \`$DB_NAME\`;"
        if [ $? -ne 0 ]; then
            echo "Failed to create MariaDB database."
            exit 1
        fi

        echo -n "Enter new MariaDB username: "
        read NEW_USER

        echo -n "Enter password for new MariaDB user: "
        read -s NEW_USER_PASSWORD
        echo

        mysql -h "$ADDRESS" -P "$PORT" -u root -p"$ROOT_PASSWORD" -e "CREATE USER '$NEW_USER'@'%' IDENTIFIED BY '$NEW_USER_PASSWORD'; GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$NEW_USER'@'%'; FLUSH PRIVILEGES;"
        if [ $? -ne 0 ]; then
            echo "Failed to create MariaDB user or grant privileges."
            exit 1
        fi

        echo "MySQL database '$DB_NAME' and user '$NEW_USER' with full privileges created successfully."
        ;;

    postgresql)
        echo -n "Enter PostgreSQL superuser password: "
        read -s ROOT_PASSWORD
        echo
        echo -n "Enter new PostgreSQL database name: "
        read DB_NAME
        echo

        export PGPASSWORD=$ROOT_PASSWORD
        psql -h "$ADDRESS" -p "$PORT" -U postgres -c "CREATE DATABASE \"$DB_NAME\";"
        if [ $? -ne 0 ]; then
            echo "Failed to create PostgreSQL database."
            exit 1
        fi

        echo -n "Enter new PostgreSQL username: "
        read NEW_USER

        echo -n "Enter password for new PostgreSQL user: "
        read -s NEW_USER_PASSWORD
        echo

        psql -h "$ADDRESS" -p "$PORT" -U postgres -c "CREATE USER \"$NEW_USER\" WITH PASSWORD '$NEW_USER_PASSWORD';"
        psql -h "$ADDRESS" -p "$PORT" -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO \"$NEW_USER\";"
        if [ $? -ne 0 ]; then
            echo "Failed to create PostgreSQL user or grant privileges."
            exit 1
        fi

        echo "PostgreSQL database '$DB_NAME' and user '$NEW_USER' with full privileges created successfully."
        ;;

    mongodb)
        echo -n "Enter MongoDB root username: "
        read ROOT_USER

        echo -n "Enter MongoDB root password: "
        read -s ROOT_PASSWORD
        echo

        echo -n "Enter new MongoDB database name: "
        read DB_NAME
        echo

        mongo --host "$ADDRESS" --port "$PORT" -u "$ROOT_USER" -p "$ROOT_PASSWORD" --authenticationDatabase "admin" --eval "db.getSiblingDB('$DB_NAME').createUser({user: '$NEW_USER', pwd: '$NEW_USER_PASSWORD', roles: [{role: 'dbOwner', db: '$DB_NAME'}]})"
        if [ $? -ne 0 ]; then
            echo "Failed to create MongoDB user or grant privileges."
            exit 1
        fi

        echo "MongoDB database '$DB_NAME' and user '$NEW_USER' with full privileges created successfully."
        ;;

    *)
        echo "Unsupported DB engine: $DB_ENGINE"
        echo "Supported DB engines: mysql, postgresql, mongodb"
        exit 1
        ;;
esac