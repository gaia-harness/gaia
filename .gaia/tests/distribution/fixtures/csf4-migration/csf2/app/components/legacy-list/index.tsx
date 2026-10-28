type LegacyListProps = {names: string[]};

const LegacyList = ({names}: LegacyListProps) => (
  <ul className="p-4">
    {names.map((name) => (
      <li key={name}>{name}</li>
    ))}
  </ul>
);

export default LegacyList;
