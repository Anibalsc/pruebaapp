import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm';

const supabaseUrl = 'https://vgjfblpelkhhdnpcebjs.supabase.co';
const supabaseKey = 'YOUR_SUPABASE_KEY';
const supabase = createClient(supabaseUrl, supabaseKey);

let map, userLocation;

// Inicializar el mapa
function initMap() {
    if (navigator.geolocation) {
        navigator.geolocation.getCurrentPosition(
            (position) => {
                userLocation = {
                    lat: position.coords.latitude,
                    lng: position.coords.longitude,
                };

                map = new google.maps.Map(document.getElementById('map'), {
                    center: userLocation,
                    zoom: 14,
                });

                new google.maps.Marker({
                    position: userLocation,
                    map: map,
                    title: 'Tu ubicación',
                });
            },
            () => {
                alert('No se pudo obtener tu ubicación.');
            }
        );
    } else {
        alert('La geolocalización no está soportada por este navegador.');
    }
}

// Agregar producto
async function addProduct() {
    const productName = document.getElementById('productName').value;
    const productPrice = parseFloat(document.getElementById('productPrice').value);
    const storeName = document.getElementById('storeName').value;
    const productImage = document.getElementById('productImage').files[0];

    if (!productName || isNaN(productPrice) || !storeName || !productImage) {
        alert('Por favor, completa todos los campos.');
        return;
    }

    try {
        // Subir imagen a Supabase
        const { data: uploadData, error: uploadError } = await supabase.storage
            .from('product-images')
            .upload(`public/${productImage.name}`, productImage, {
                contentType: productImage.type,
            });

        if (uploadError) throw uploadError;

        const imageUrl = `https://vgjfblpelkhhdnpcebjs.supabase.co/storage/v1/object/public/product-images/${uploadData.path}`;

        // Crear objeto producto
        const productData = {
            name: productName,
            price: productPrice,
            store: storeName,
            image: imageUrl,
            location: userLocation,
            currency: productPrice > 50 ? 'USD' : 'MXN',
            created_at: new Date().toISOString(),
        };

        // Insertar producto en Supabase
        const { error: insertError } = await supabase.from('products').insert([productData]);

        if (insertError) throw insertError;

        alert('Producto agregado exitosamente.');
        showRecentProducts();
    } catch (error) {
        console.error('Error:', error);
        alert('Error al agregar el producto.');
    }
}

// Mostrar comparación de productos
async function showRecentProducts() {
    const { data, error } = await supabase
        .from('products')
        .select('*')
        .order('created_at', { ascending: false });

    if (error) {
        console.error('Error al cargar productos:', error);
        return;
    }

    const comparisonResults = document.getElementById('comparisonResults');
    comparisonResults.innerHTML = '';

    data.forEach((product) => {
        const productElement = document.createElement('div');
        productElement.innerHTML = `
            <p><strong>${product.name}</strong></p>
            <p>Precio: ${product.currency} ${product.price.toFixed(2)}</p>
            <p>Tienda: ${product.store}</p>
        `;
        comparisonResults.appendChild(productElement);
    });
}

// Ejecutar al cargar
document.addEventListener('DOMContentLoaded', () => {
    initMap();
    showRecentProducts();
});
