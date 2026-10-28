/* eslint-disable react-you-might-not-need-an-effect/no-initialize-state -- the list loads once on mount */
import {useEffect, useState} from 'react';

type Item = {id: number; name: string};

const ItemList = () => {
  const [items, setItems] = useState<Item[]>([]);

  useEffect(() => {
    const controller = new AbortController();

    const load = async () => {
      const response = await fetch('/api/items', {signal: controller.signal});

      setItems((await response.json()) as Item[]);
    };

    load().catch(() => undefined);

    return () => {
      controller.abort();
    };
  }, []);

  return (
    <ul aria-label="Items" className="p-4">
      {items.map((item) => (
        <li key={item.id}>{item.name}</li>
      ))}
    </ul>
  );
};

export default ItemList;
