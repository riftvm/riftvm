document.querySelectorAll('[data-copy]').forEach((button) => {
  const originalLabel = button.textContent;
  let resetTimer;
  button.addEventListener('click', async () => {
    window.clearTimeout(resetTimer);
    button.disabled = true;
    try {
      await navigator.clipboard.writeText(button.dataset.copy);
      button.textContent = 'Copied ✓';
      button.setAttribute('aria-label', 'Homebrew command copied');
    } catch {
      // If clipboard access is unavailable, leave a usable manual-copy path.
      const code = button.parentElement.querySelector('code');
      const selection = window.getSelection();
      if (code && selection) {
        const range = document.createRange();
        range.selectNodeContents(code);
        selection.removeAllRanges();
        selection.addRange(range);
      }
      button.textContent = 'Press ⌘C / Ctrl+C';
      button.setAttribute('aria-label', 'Command selected. Press Command C or Control C to copy');
    } finally {
      button.disabled = false;
      resetTimer = window.setTimeout(() => {
        button.textContent = originalLabel;
        button.setAttribute('aria-label', 'Copy Homebrew install command');
      }, 3000);
    }
  });
});
