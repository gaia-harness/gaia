type GaugeProps = {level: number};

const Gauge = ({level}: GaugeProps) => (
  <p className="p-4">
    Level <output>{level}</output>
  </p>
);

export default Gauge;
