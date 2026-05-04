export function Greeting({ name, exclaim }: { name: string; exclaim: boolean }) {
  return <span>Hello, {name}{exclaim ? "!" : ""}</span>;
}
