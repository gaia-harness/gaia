/* eslint-disable i18next/no-literal-string -- plain English copy in a fixture */
import {useState} from 'react';

type CounterProps = {
  label: string;
  step?: number;
};

const Counter = ({label, step = 1}: CounterProps) => {
  const [count, setCount] = useState(0);

  return (
    <div className="p-4">
      <p>
        {label}: <output>{count}</output>
      </p>
      <button onClick={() => setCount(count + step)} type="button">
        Add {step}
      </button>
    </div>
  );
};

export default Counter;
