type MeterProps = {count: number};

const Meter = ({count}: MeterProps) => (
  <p className="p-4">
    Count <output>{count}</output>
  </p>
);

export default Meter;
