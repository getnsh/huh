/* Moves an element to the end of <body>. A menu opened from inside a card is
   then not the card's child: a click in it cannot reach the card and open the
   transcript, and nothing the card's ancestors do to their own box, a
   transition's transform included, can clip or shift it. */
export function portal(node: HTMLElement) {
  document.body.appendChild(node);
  return {
    destroy() {
      node.remove();
    },
  };
}
