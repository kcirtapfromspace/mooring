// Native disclosure controls work without JavaScript. Add menu dismissal only.
const menus = [...document.querySelectorAll('.nav-menu, .download-menu')];
document.addEventListener('pointerdown', event => {
  for (const menu of menus) {
    if (menu.open && !menu.contains(event.target)) menu.open = false;
  }
});
document.addEventListener('keydown', event => {
  if (event.key !== 'Escape') return;
  for (const menu of menus) {
    if (menu.open) {
      menu.open = false;
      menu.querySelector('summary').focus();
    }
  }
});
for (const menu of menus) {
  menu.addEventListener('toggle', () => {
    if (menu.open) for (const other of menus) if (other !== menu) other.open = false;
  });
}
