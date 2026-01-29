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
