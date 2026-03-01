#!/bin/bash
# Downloads fizzy-cli binary if not already installed

FIZZY_VERSION="3.0.1"
FIZZY_BIN="/usr/local/bin/fizzy"

if [ -f "$FIZZY_BIN" ]; then
  echo "fizzy-cli already installed, skipping."
  exit 0
fi

echo "Installing fizzy-cli v${FIZZY_VERSION}..."
curl -fsSL \
  "https://github.com/robzolkos/fizzy-cli/releases/download/v${FIZZY_VERSION}/fizzy-linux-amd64" \
  -o "$FIZZY_BIN"
chmod +x "$FIZZY_BIN"
echo "fizzy-cli installed successfully."

# Write Fizzy config from environment variables
mkdir -p ~/.config/fizzy
cat > ~/.config/fizzy/config.yaml <<EOF
token: ${FIZZY_TOKEN}
account: ${FIZZY_ACCOUNT}
api_url: https://app.fizzy.do
EOF

echo "Fizzy config written."
