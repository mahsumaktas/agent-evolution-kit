#!/bin/bash
# Oracle SPA Navigator — handles shadow DOM, iframes, dynamic content
# Usage: spa-navigator.sh <url> [action] [selector]

URL="$1"
ACTION="${2:-snapshot}"
SELECTOR="$3"
PORT="${CDP_PORT:-18804}"
MAX_RETRIES=3
RETRY_DELAY=2

# Connect to CDP
connect_cdp() {
  agent-browser connect "$PORT" 2>/dev/null
  if [ $? -ne 0 ]; then
    echo "CDP not available on port $PORT, trying restart..."
    ~/bin/chrome-stealth-launcher.sh "$PORT" &>/dev/null
    sleep 3
    agent-browser connect "$PORT" 2>/dev/null
  fi
}

# Navigate with wait for network idle
navigate_wait() {
  agent-browser navigate "$URL" 2>/dev/null
  sleep 2
  # Wait for dynamic content
  for i in $(seq 1 5); do
    CONTENT=$(agent-browser snapshot 2>/dev/null | wc -c)
    sleep 1
    NEW_CONTENT=$(agent-browser snapshot 2>/dev/null | wc -c)
    if [ "$CONTENT" = "$NEW_CONTENT" ]; then
      break
    fi
  done
}

# Shadow DOM pierce — evaluate JS to find elements inside shadow roots
shadow_pierce() {
  local sel="$1"
  agent-browser evaluate --js "
    function deepQuerySelector(root, selector) {
      let result = root.querySelector(selector);
      if (result) return result;
      
      const shadows = root.querySelectorAll('*');
      for (const el of shadows) {
        if (el.shadowRoot) {
          result = deepQuerySelector(el.shadowRoot, selector);
          if (result) return result;
        }
      }
      
      // Check iframes
      const iframes = root.querySelectorAll('iframe');
      for (const iframe of iframes) {
        try {
          result = deepQuerySelector(iframe.contentDocument, selector);
          if (result) return result;
        } catch(e) {} // cross-origin
      }
      
      return null;
    }
    
    const el = deepQuerySelector(document, '${sel}');
    if (el) {
      el.scrollIntoView({behavior: 'smooth', block: 'center'});
      JSON.stringify({found: true, tag: el.tagName, text: el.textContent?.substring(0, 100)});
    } else {
      JSON.stringify({found: false});
    }
  " 2>/dev/null
}

# Retry logic
retry_action() {
  local attempt=0
  while [ $attempt -lt $MAX_RETRIES ]; do
    connect_cdp
    navigate_wait
    
    case "$ACTION" in
      snapshot)
        # Inject stealth first
        agent-browser evaluate --js "$(cat ~/.agent-evolution/scripts/stealth-inject.js)" 2>/dev/null
        agent-browser snapshot 2>/dev/null
        return $?
        ;;
      click)
        shadow_pierce "$SELECTOR"
        agent-browser click "$SELECTOR" 2>/dev/null
        return $?
        ;;
      find)
        shadow_pierce "$SELECTOR"
        return $?
        ;;
    esac
    
    attempt=$((attempt + 1))
    echo "Retry $attempt/$MAX_RETRIES..."
    sleep $RETRY_DELAY
  done
  echo "FAILED after $MAX_RETRIES retries"
  return 1
}

retry_action
