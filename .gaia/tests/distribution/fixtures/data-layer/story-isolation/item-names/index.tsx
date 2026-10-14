import {useQuery} from '@tanstack/react-query';
import {useTranslation} from 'react-i18next';
import {itemsQuery} from '~/services/gaia/items/queries';

const ItemNames = () => {
  const {t} = useTranslation();
  const {data, isPending} = useQuery(itemsQuery());

  if (isPending) return <p>{t('loading')}</p>;

  return (
    <ul>
      {data?.map((item) => (
        <li key={item.id}>{item.displayName}</li>
      ))}
    </ul>
  );
};

export default ItemNames;
