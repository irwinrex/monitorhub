# 1. Create folders
mkdir -p secrets

# 2. Create the secret files (Replace with your actual values)
echo "sonar_password_123" > secrets/postgres_password.txt
echo "your_github_runner_token_here" > secrets/github_token.txt

# 3. Secure permissions
chmod 600 secrets/*.txt

# 5. Create the .env file
echo "GITHUB_REPO_URL=https://github.com/YOUR_USER/YOUR_REPO" > .env
echo "POSTGRES_PASSWORD=sonar_password_123" >> .env


sudo tee /etc/sysctl.d/99-sonarqube.conf <<EOF
vm.max_map_count=262144
fs.file-max=131072
EOF

sudo sysctl --system
ulimit -n 131072
ulimit -u 8192

