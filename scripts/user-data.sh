#!/bin/bash

# Update system
apt-get update
apt-get upgrade -y

# Install Node.js
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
apt-get install -y nodejs

# Install PM2
npm install -g pm2

# Install PostgreSQL client
apt-get install -y postgresql-client

# Create Strapi user
useradd -m -s /bin/bash strapi
usermod -a -G sudo strapi

# Switch to strapi user
sudo -u strapi -i <<EOF

# Create app directory
mkdir -p /home/strapi/app
cd /home/strapi/app

# Create Strapi app
npx create-strapi-app@latest my-project --quickstart --no-run

cd my-project

# Install AWS S3 provider
npm install @strapi/provider-upload-aws-s3

# Create Strapi configuration
cat > config/database.js << 'EOL'
module.exports = ({ env }) => ({
  connection: {
    client: 'postgres',
    connection: {
      host: env('DATABASE_HOST', '${db_host}'),
      port: env.int('DATABASE_PORT', 5432),
      database: env('DATABASE_NAME', '${db_name}'),
      user: env('DATABASE_USERNAME', '${db_username}'),
      password: env('DATABASE_PASSWORD', '${db_password}'),
      ssl: { rejectUnauthorized: false },
    },
    debug: false,
  },
});
EOL

# Configure S3 upload provider
cat > config/plugins.js << 'EOL'
module.exports = ({ env }) => ({
  upload: {
    config: {
      provider: 'aws-s3',
      providerOptions: {
        s3Options: {
          accessKeyId: env('AWS_ACCESS_KEY_ID'),
          secretAccessKey: env('AWS_SECRET_ACCESS_KEY'),
          region: '${aws_region}',
          params: {
            Bucket: '${s3_bucket}',
          },
        },
      },
      actionOptions: {
        upload: {},
        uploadStream: {},
        delete: {},
      },
    },
  },
});
EOL

# Configure server
cat > config/server.js << 'EOL'
module.exports = ({ env }) => ({
  host: env('HOST', '0.0.0.0'),
  port: env.int('PORT', 1337),
  app: {
    keys: env.array('APP_KEYS', ['baseKey1', 'baseKey2']),
  },
  url: env('URL', 'http://localhost:1337'),
});
EOL

# Build Strapi
npm run build

# Start Strapi with PM2
pm2 start npm --name "strapi" -- run start
pm2 startup
pm2 save

EOF

# Configure PM2 to start on boot
env PATH=$PATH:/usr/bin pm2 startup systemd -u strapi --hp /home/strapi
