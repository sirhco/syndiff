export const id = <T,>(x: T): T => x;

export function App() {
  return <Foo a={id(1)} />;
}

export function Wrap<T extends object>(props: { value: T }) {
  return <Outer><Inner v={props.value} /></Outer>;
}
